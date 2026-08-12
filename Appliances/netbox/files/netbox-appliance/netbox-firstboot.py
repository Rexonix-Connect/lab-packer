#!/usr/bin/env python3
"""Bootstrap a deployed NetBox appliance from the vSphere deploy form.

The exported template carries no secret and no identity: no NetBox
configuration, no TLS key, no superuser, no machine id. This runs once on the
first boot of a deployment and creates all of it, taking whatever the operator
filled into the deploy form and generating the rest. Leaving the whole form
empty is a supported, and the recommended, way to deploy: everything is then
generated, and the admin password is printed on the VM console and written to
/root/netbox-credentials.txt.

netbox.service, netbox-rq.service and nginx.service are ordered after this and
require it, so a failure here leaves the appliance visibly down rather than
half configured. Re-run it with:

    systemctl start netbox-bootstrap

With --reconcile (netbox-reconcile.service, every subsequent boot) it only
re-derives the host names the appliance answers to and refreshes a generated
certificate; secrets, the database and the superuser are never touched.
"""
import argparse
import base64
import binascii
import datetime
import importlib.util
import ipaddress
import json
import os
import re
import secrets
import socket
import string
import subprocess
import sys
import traceback

STATE_DIR = '/var/lib/netbox-appliance'
MARKER = os.path.join(STATE_DIR, 'bootstrapped')
FAILURE = os.path.join(STATE_DIR, 'failed')
STATE = os.path.join(STATE_DIR, 'state.json')

CONFIG = '/etc/netbox/appliance.json'
TLS_DIR = '/etc/netbox/tls'
CERT = os.path.join(TLS_DIR, 'netbox.crt')
KEY = os.path.join(TLS_DIR, 'netbox.key')
SELF_SIGNED = os.path.join(TLS_DIR, '.self-signed')

CREDENTIALS = '/root/netbox-credentials.txt'
ISSUE = '/etc/issue.d/60-netbox.issue'

NETBOX_ROOT = '/opt/netbox'
VENV_PYTHON = os.path.join(NETBOX_ROOT, 'venv/bin/python')
MANAGE = os.path.join(NETBOX_ROOT, 'netbox/manage.py')
MANAGE_CWD = os.path.join(NETBOX_ROOT, 'netbox')
OVF_SETTINGS = '/usr/local/sbin/ovf-settings.py'

SNIPPET_SERVER_NAME = '/etc/nginx/snippets/netbox-server-name.conf'
SNIPPET_METRICS = '/etc/nginx/snippets/netbox-metrics.conf'
SNIPPET_HSTS = '/etc/nginx/snippets/netbox-hsts.conf'

PASSWORD_ALPHABET = string.ascii_letters + string.digits + '!@#%^*-_=+'
UNSET_HOSTNAMES = {'', 'localhost', 'localhost.localdomain', '(none)'}

# Deploy-form values end up in nginx directives and certificate SANs, so they
# are untrusted input to a config parser. Anything that is not a plain DNS name
# is dropped rather than escaped: a semicolon or newline would inject an nginx
# directive, and a value nginx or openssl merely dislikes would fail the
# bootstrap and take the whole appliance down with it.
DNS_NAME_RE = re.compile(
    r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*\.?$')


def is_dns_name(value):
    return bool(value) and len(value) <= 253 and bool(DNS_NAME_RE.match(value))


def log(message):
    print('netbox-firstboot: %s' % message, flush=True)


def run(command, **kwargs):
    kwargs.setdefault('check', True)
    kwargs.setdefault('text', True)
    return subprocess.run(command, **kwargs)


def capture(command, **kwargs):
    kwargs.setdefault('text', True)
    kwargs.setdefault('capture_output', True)
    result = subprocess.run(command, **kwargs)
    return result.stdout.strip() if result.returncode == 0 else ''


def manage(*args, env=None, capture_output=False):
    """Run a NetBox management command as the netbox account.

    The local database authenticates by peer over the Unix socket, so the
    connecting account has to be netbox, not root.
    """
    command = ['runuser', '-u', 'netbox', '--', VENV_PYTHON, MANAGE] + list(args)
    environment = dict(os.environ)
    environment.setdefault('HOME', '/tmp')
    if env:
        environment.update(env)
    return subprocess.run(command, cwd=MANAGE_CWD, env=environment, text=True,
                          check=not capture_output,
                          capture_output=capture_output)


#
# Deploy form
#

def ovf_properties():
    """Read the OVF environment using the base image's own parser.

    ovf-settings.py already handles the guestinfo transport, the namespace
    quirks and the value extraction, and it ships in every lab-packer Ubuntu
    template, so this reuses it rather than carrying a second XML parser.
    """
    if not os.path.exists(OVF_SETTINGS):
        log('%s is missing; every value falls back to a generated default'
            % OVF_SETTINGS)
        return {}
    # get_ovf_env() treats a first argument as a file to read for testing, and
    # this script has its own arguments, so hide them for the duration.
    saved_argv = sys.argv
    sys.argv = [saved_argv[0]]
    try:
        spec = importlib.util.spec_from_file_location('ovf_settings',
                                                      OVF_SETTINGS)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        xml_text = module.get_ovf_env()
        if not xml_text:
            log('no OVF environment available; every value falls back to a'
                ' generated default')
            return {}
        return module.parse_props(xml_text)
    except Exception as exc:
        log('could not read the OVF environment (%s); every value falls back'
            ' to a generated default' % exc)
        return {}
    finally:
        sys.argv = saved_argv


def prop(props, key, default=''):
    return (props.get(key) or '').strip() or default


#
# Identity
#

def local_addresses():
    """Every non-loopback, non-link-local address the guest currently holds."""
    addresses = []
    output = capture(['ip', '-json', 'address', 'show', 'up'])
    if not output:
        return addresses
    try:
        interfaces = json.loads(output)
    except ValueError:
        return addresses
    for interface in interfaces:
        if interface.get('link_type') == 'loopback':
            continue
        for entry in interface.get('addr_info', []):
            address = entry.get('local', '')
            scope = entry.get('scope', '')
            if not address or scope in ('host', 'link'):
                continue
            addresses.append(address)
    return addresses


def resolve_identity(props):
    """Return (fqdn, allowed_hosts, addresses).

    The FQDN is what the certificate is issued for and what the operator is
    told to browse to: the form's value if given, otherwise the guest's own
    name, otherwise its first address.
    """
    addresses = local_addresses()
    hostname = socket.gethostname()

    fqdn = prop(props, 'netbox.fqdn') or prop(props, 'hostname')
    if fqdn and not is_dns_name(fqdn):
        log('ignoring %r from the deploy form: not a valid host name' % fqdn)
        fqdn = ''
    if not fqdn and hostname.lower() not in UNSET_HOSTNAMES:
        resolved = socket.getfqdn()
        candidate = (resolved if resolved.lower() not in UNSET_HOSTNAMES
                     else hostname)
        fqdn = candidate if is_dns_name(candidate) else ''
    domain = prop(props, 'network.domain').replace(',', ' ').split()
    if fqdn and '.' not in fqdn and domain:
        qualified = '%s.%s' % (fqdn, domain[0])
        if is_dns_name(qualified):
            fqdn = qualified
    if not fqdn and addresses:
        # No name anywhere: the first address at least gives the operator a URL
        # to browse to. It is not a DNS name, so it is kept out of the nginx
        # server_name directive - "_" already answers on every Host.
        fqdn = addresses[0]

    hosts = []
    for candidate in [fqdn, hostname, fqdn.split('.')[0] if fqdn else '']:
        if candidate and candidate.lower() not in UNSET_HOSTNAMES:
            hosts.append(candidate)
    for address in addresses:
        hosts.append(address)
        if ':' in address:
            # Django compares the Host header with IPv6 literals bracketed.
            hosts.append('[%s]' % address)
    hosts.extend(['localhost', '127.0.0.1', '[::1]'])

    seen = set()
    unique = []
    for host in hosts:
        if host not in seen:
            seen.add(host)
            unique.append(host)
    return fqdn, unique, addresses


#
# Configuration
#

def split_host_port(value, default_port):
    value = value.strip()
    if value.startswith('['):
        host, _, rest = value.partition(']')
        host = host[1:]
        port = rest.lstrip(':')
        return host, port or default_port
    if value.count(':') == 1:
        host, _, port = value.partition(':')
        return host, port or default_port
    return value, default_port


def build_database(props):
    """Local PostgreSQL over the Unix socket, or an external server."""
    host = prop(props, 'netbox.db-host')
    if not host:
        return {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': 'netbox',
            'USER': 'netbox',
            # Empty host means the Unix socket, where the local cluster
            # authenticates by peer, so there is no password to store.
            'PASSWORD': '',
            'HOST': '',
            'PORT': '',
            'CONN_MAX_AGE': 300,
        }, True
    host, port = split_host_port(host, '5432')
    return {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': prop(props, 'netbox.db-name', 'netbox'),
        'USER': prop(props, 'netbox.db-user', 'netbox'),
        'PASSWORD': prop(props, 'netbox.db-password'),
        'HOST': host,
        'PORT': port,
        'CONN_MAX_AGE': 300,
    }, False


def build_redis(props):
    host = prop(props, 'netbox.redis-host')
    password = prop(props, 'netbox.redis-password')
    if host:
        host, port = split_host_port(host, '6379')
    else:
        host, port = 'localhost', '6379'
    def instance(database):
        return {
            'HOST': host,
            'PORT': int(port),
            'USERNAME': '',
            'PASSWORD': password,
            'DATABASE': database,
            'SSL': False,
        }
    return {'tasks': instance(0), 'caching': instance(1)}


def generate_secret():
    """A NetBox SECRET_KEY or API token pepper: at least 50 characters."""
    if os.path.exists(VENV_PYTHON):
        generated = capture([VENV_PYTHON, 'generate_secret_key.py'],
                            cwd=MANAGE_CWD)
        if len(generated) >= 50:
            return generated
    return secrets.token_urlsafe(64)[:60]


def load_config():
    with open(CONFIG) as handle:
        return json.load(handle)


def write_config(config):
    directory = os.path.dirname(CONFIG)
    os.makedirs(directory, mode=0o750, exist_ok=True)
    descriptor = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    with os.fdopen(descriptor, 'w') as handle:
        json.dump(config, handle, indent=2, sort_keys=True)
        handle.write('\n')
    run(['chown', 'root:netbox', CONFIG])


#
# TLS
#

def decode_pem(value, label):
    """Accept the form's base64, or a PEM pasted in directly."""
    if '-----BEGIN' in value:
        return value.encode()
    compact = re.sub(r'\s+', '', value)
    try:
        return base64.b64decode(compact, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise RuntimeError('%s is neither PEM nor valid base64: %s'
                           % (label, exc))


def install_operator_certificate(props):
    """Install the supplied certificate and key, or return False.

    A supplied-but-broken pair fails the bootstrap on purpose: silently
    serving a self-signed certificate where the operator asked for a real one
    is exactly the kind of surprise a production appliance must not spring.
    """
    cert_value = prop(props, 'netbox.tls-cert')
    key_value = prop(props, 'netbox.tls-key')
    if not cert_value and not key_value:
        return False
    if not cert_value or not key_value:
        raise RuntimeError('netbox.tls-cert and netbox.tls-key must be given'
                           ' together')

    certificate = decode_pem(cert_value, 'netbox.tls-cert')
    private_key = decode_pem(key_value, 'netbox.tls-key')
    write_file(CERT, certificate, 0o644, 'root:root')
    write_file(KEY, private_key, 0o640, 'root:www-data')

    cert_pub = capture(['openssl', 'x509', '-noout', '-pubkey', '-in', CERT])
    key_pub = capture(['openssl', 'pkey', '-pubout', '-in', KEY])
    if not cert_pub or not key_pub or cert_pub != key_pub:
        raise RuntimeError('netbox.tls-key does not match netbox.tls-cert')

    if os.path.exists(SELF_SIGNED):
        os.remove(SELF_SIGNED)
    log('installed the operator-supplied TLS certificate')
    return True


def generate_certificate(fqdn, hosts, addresses):
    names = []
    for host in [fqdn] + hosts:
        if not host or host.startswith('[') or host in ('127.0.0.1',):
            continue
        if host in addresses:
            continue
        entry = 'DNS:%s' % host
        if entry not in names:
            names.append(entry)
    for address in addresses + ['127.0.0.1']:
        entry = 'IP:%s' % address
        if entry not in names:
            names.append(entry)
    if not names:
        names = ['DNS:localhost', 'IP:127.0.0.1']

    os.makedirs(TLS_DIR, mode=0o755, exist_ok=True)
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:4096', '-sha256',
         '-days', '3650', '-nodes',
         '-keyout', KEY, '-out', CERT,
         '-subj', '/CN=%s' % (fqdn or 'netbox'),
         '-addext', 'subjectAltName=%s' % ','.join(names)],
        capture_output=True)
    run(['chown', 'root:www-data', KEY])
    os.chmod(KEY, 0o640)
    os.chmod(CERT, 0o644)
    with open(SELF_SIGNED, 'w') as handle:
        handle.write('%s\n' % ','.join(names))
    log('generated a self-signed certificate for %s' % ', '.join(names))


def write_file(path, content, mode, owner=None):
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(descriptor, 'wb' if isinstance(content, bytes) else 'w') as handle:
        handle.write(content)
    os.chmod(path, mode)
    if owner:
        run(['chown', owner, path])


#
# nginx
#

def write_nginx_snippets(fqdn, metrics_allow, operator_certificate):
    # fqdn is an address when the deployment has no name of its own, and comes
    # from the deploy form otherwise, so only a real DNS name is written into
    # the directive. "_" matches every Host either way, so nothing is lost.
    name = fqdn if is_dns_name(fqdn) else ''
    server_name = 'server_name %s_;\n' % ('%s ' % name if name else '')
    write_file(SNIPPET_SERVER_NAME,
               '# Written by netbox-firstboot.py.\n' + server_name, 0o644)

    lines = ['# Written by netbox-firstboot.py.\n']
    # Re-checked at the sink, so this stays safe however it is called.
    lines.extend('allow %s;\n' % entry for entry in metrics_allow
                 if is_allow_entry(entry))
    lines.append('deny all;\n')
    write_file(SNIPPET_METRICS, ''.join(lines), 0o644)

    hsts = '# Written by netbox-firstboot.py.\n'
    if operator_certificate:
        hsts += ('add_header Strict-Transport-Security'
                 ' "max-age=31536000; includeSubDomains" always;\n')
    else:
        hsts += ('# Not sent: the certificate is self-signed, and HSTS would'
                 ' make the\n# browser warning impossible to click through.\n')
    write_file(SNIPPET_HSTS, hsts, 0o644)

    run(['nginx', '-t'], capture_output=True)


def is_allow_entry(entry):
    """Is this safe to write into an nginx "allow" directive?

    Checked here and again at the point of writing, because a stray semicolon
    would inject a directive and a plain typo would fail nginx's configuration
    test and, with it, the whole bootstrap.
    """
    try:
        ipaddress.ip_network(entry, strict=False)
    except ValueError:
        return False
    return True


def parse_allowlist(value):
    """Addresses and networks for the nginx metrics allowlist.

    A rejected entry is dropped rather than fatal: that keeps NetBox serving
    and leaves the scraper locked out, which is the safe way round.
    """
    entries = []
    for entry in re.split(r'[,\s]+', value):
        if not entry:
            continue
        if not is_allow_entry(entry):
            log('ignoring %r in netbox.metrics-allow: not an address or CIDR'
                % entry)
            continue
        entries.append(entry)
    return entries


#
# Superuser and credentials
#

def superuser_exists():
    result = manage('shell', '-c',
                    'from django.contrib.auth import get_user_model;'
                    'print(get_user_model().objects.filter('
                    'is_superuser=True).count())',
                    capture_output=True)
    if result.returncode != 0:
        raise RuntimeError('could not query existing users: %s'
                           % (result.stderr or result.stdout).strip())
    for line in reversed(result.stdout.strip().splitlines()):
        try:
            return int(line.strip()) > 0
        except ValueError:
            continue
    raise RuntimeError('could not parse the user count from: %s'
                       % result.stdout.strip())


def create_superuser(username, email, password):
    manage('createsuperuser', '--noinput',
           '--username', username, '--email', email,
           env={'DJANGO_SUPERUSER_PASSWORD': password})


def write_credentials(state, password, generated):
    lines = [
        'NetBox appliance credentials',
        '============================',
        '',
        'URL:      %s' % state['url'],
        'Username: %s' % state['admin_username'],
        'Password: %s' % (password if password else '(unchanged - the database'
                          ' already had a superuser)'),
        '',
        'This file is written once, by the first-boot bootstrap. Change the',
        'password in NetBox and then remove it:',
        '',
        '    netbox-credentials --clear',
        '',
        'Generated at %s for NetBox %s.' % (state['bootstrapped_at'],
                                            state['netbox_version']),
        '',
    ]
    write_file(CREDENTIALS, '\n'.join(lines), 0o600)

    if generated and password:
        # The console banner exists because a generated password is otherwise
        # unreachable: there is no account to log in with over SSH yet unless
        # the deploy form supplied one. /etc/issue is the local console only -
        # the hardened base uses /etc/issue.net as the pre-authentication SSH
        # banner, which must never carry this.
        banner = (
            '\n'
            'NetBox appliance -- %s\n'
            '  admin user: %s\n'
            '  password:   %s\n'
            '  Remove this banner after the first login:'
            ' netbox-credentials --clear\n'
            '\n' % (state['url'], state['admin_username'], password)
        )
        write_file(ISSUE, banner, 0o600)


#
# Bootstrap
#

def netbox_version():
    version = capture(['git', '-C', NETBOX_ROOT, 'describe', '--tags',
                       '--exact-match'])
    return version or capture(['git', '-C', NETBOX_ROOT, 'describe', '--tags',
                               '--always']) or 'unknown'


def system_is_booting():
    """True while systemd is still bringing multi-user.target up."""
    result = subprocess.run(['systemctl', 'is-system-running'],
                            text=True, capture_output=True)
    # Exits non-zero for anything but "running", so the exit status cannot be
    # used to tell "still booting" from "up but degraded"; the word on stdout
    # can.
    return result.stdout.strip() in ('initializing', 'starting')


def restart_services():
    """Pick up the new configuration - but never during boot.

    netbox.service, netbox-rq.service and nginx.service are ordered after this
    unit, so at boot they already have start jobs queued behind it. systemctl's
    default job mode is "replace": a newly enqueued job replaces the queued one
    unless the two types are mergeable, and that is where the two behave
    differently.

    nginx has an ExecReload, so try-reload-or-restart becomes a reload-type
    job, which does merge with a pending start - nginx comes up. NetBox's
    units, straight from upstream contrib/, have no ExecReload, so the request
    degrades to try-restart, which is not mergeable with a pending start: the
    queued start is cancelled, try-restart then does nothing because the unit
    is not running, and it stays inactive forever.

    That asymmetry is precisely what the first deployment showed - nginx
    active, netbox and netbox-rq inactive rather than failed, after a bootstrap
    that reported success. So at boot this does nothing at all and lets the
    ordering start them; only a manual re-run, where the services are already
    up and there is no queued job to clobber, actually restarts anything.
    """
    if system_is_booting():
        log('boot in progress; netbox, netbox-rq and nginx start from their'
            ' own ordering')
        return
    run(['systemctl', 'try-reload-or-restart',
         'netbox.service', 'netbox-rq.service', 'nginx.service'], check=False)


def bootstrap(props):
    fqdn, hosts, addresses = resolve_identity(props)
    log('identity: fqdn=%s hosts=%s' % (fqdn or '(none)', ','.join(hosts)))

    database, local_database = build_database(props)
    metrics_allow = parse_allowlist(prop(props, 'netbox.metrics-allow'))

    config = {
        'allowed_hosts': hosts,
        'database': database,
        'redis': build_redis(props),
        'secret_key': generate_secret(),
        'api_token_peppers': {'1': generate_secret()},
        'time_zone': prop(props, 'netbox.time-zone', 'UTC'),
        'metrics_enabled': bool(metrics_allow),
        'plugins': [],
        'plugins_config': {},
    }
    write_config(config)
    log('wrote %s (%s database, metrics %s)'
        % (CONFIG, 'local' if local_database else 'external',
           'on' if metrics_allow else 'off'))

    operator_certificate = install_operator_certificate(props)
    if not operator_certificate:
        generate_certificate(fqdn, hosts, addresses)
    write_nginx_snippets(fqdn, metrics_allow, operator_certificate)

    if metrics_allow:
        run(['systemctl', 'enable', '--now', 'prometheus-node-exporter'],
            check=False)
    else:
        run(['systemctl', 'disable', '--now', 'prometheus-node-exporter'],
            check=False)

    log('applying database migrations')
    manage('migrate', '--no-input')
    if not local_database:
        # The image ships a migrated local database with its search index
        # already built; an external database starts empty.
        log('building the search index')
        manage('reindex', '--lazy')

    admin_username = prop(props, 'netbox.admin-username', 'admin')
    admin_email = prop(props, 'netbox.admin-email', 'admin@example.com')
    admin_password = prop(props, 'netbox.admin-password')
    generated = not admin_password
    if generated:
        admin_password = ''.join(secrets.choice(PASSWORD_ALPHABET)
                                 for _ in range(24))

    if superuser_exists():
        log('the database already has a superuser; not creating one')
        admin_password = ''
    else:
        create_superuser(admin_username, admin_email, admin_password)
        log('created the NetBox superuser %s' % admin_username)

    state = {
        'netbox_version': netbox_version(),
        'fqdn': fqdn,
        'url': 'https://%s/' % (fqdn or (addresses[0] if addresses
                                         else 'localhost')),
        'admin_username': admin_username,
        'admin_password_generated': generated and bool(admin_password),
        'database': 'local' if local_database else 'external',
        'metrics_enabled': bool(metrics_allow),
        'self_signed_certificate': not operator_certificate,
        'bootstrapped_at': datetime.datetime.now(
            datetime.timezone.utc).replace(microsecond=0).isoformat(),
    }
    write_file(STATE, json.dumps(state, indent=2, sort_keys=True) + '\n', 0o644)
    write_credentials(state, admin_password, generated)

    if os.path.exists(FAILURE):
        os.remove(FAILURE)
    write_file(MARKER, '%s\n' % state['bootstrapped_at'], 0o644)
    restart_services()
    log('bootstrap complete: %s' % state['url'])


def reconcile(props):
    """Keep host names and a generated certificate current, nothing else."""
    config = load_config()
    fqdn, hosts, addresses = resolve_identity(props)

    changed = False
    if config.get('allowed_hosts') != hosts:
        config['allowed_hosts'] = hosts
        write_config(config)
        changed = True
        log('ALLOWED_HOSTS updated to %s' % ','.join(hosts))

    state = {}
    if os.path.exists(STATE):
        with open(STATE) as handle:
            state = json.load(handle)

    if os.path.exists(SELF_SIGNED):
        with open(SELF_SIGNED) as handle:
            previous = handle.read().strip()
        expected = []
        for host in [fqdn] + hosts:
            if host and not host.startswith('[') and host not in addresses \
                    and host != '127.0.0.1':
                entry = 'DNS:%s' % host
                if entry not in expected:
                    expected.append(entry)
        for address in addresses + ['127.0.0.1']:
            entry = 'IP:%s' % address
            if entry not in expected:
                expected.append(entry)
        if previous != ','.join(expected):
            generate_certificate(fqdn, hosts, addresses)
            changed = True

    metrics_allow = parse_allowlist(prop(props, 'netbox.metrics-allow'))
    write_nginx_snippets(fqdn, metrics_allow, not os.path.exists(SELF_SIGNED))

    if state.get('fqdn') != fqdn:
        state['fqdn'] = fqdn
        state['url'] = 'https://%s/' % (fqdn or (addresses[0] if addresses
                                                 else 'localhost'))
        write_file(STATE, json.dumps(state, indent=2, sort_keys=True) + '\n',
                   0o644)
        changed = True

    if changed:
        restart_services()
        log('reconciled')
    else:
        log('nothing to reconcile')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reconcile', action='store_true',
                        help='refresh host names and a generated certificate'
                             ' only; never touch secrets or data')
    arguments = parser.parse_args()

    os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
    props = ovf_properties()
    try:
        if arguments.reconcile:
            reconcile(props)
        else:
            bootstrap(props)
    except Exception as exc:
        detail = traceback.format_exc()
        write_file(FAILURE, detail, 0o600)
        sys.stderr.write(
            '\n'
            '========================================================\n'
            ' NETBOX APPLIANCE BOOTSTRAP FAILED\n'
            ' %s\n'
            ' Details: %s\n'
            ' Retry with: systemctl start netbox-bootstrap\n'
            '========================================================\n'
            % (exc, FAILURE))
        sys.stderr.write(detail)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
