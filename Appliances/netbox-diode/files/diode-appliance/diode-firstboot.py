#!/usr/bin/env python3
"""Bootstrap a deployed NetBox Diode appliance from the vSphere deploy form.

The exported template carries no secret and no identity: no rendered compose
environment, no OAuth2 client secrets, no TLS key, no volumes, no machine id.
This runs once on the first boot of a deployment and creates all of it, taking
whatever the operator filled into the deploy form and generating the rest.

That property is worth stating plainly, because it is harder to hold here than
on the NetBox appliance. That image has no database password at all: its local
PostgreSQL authenticates by peer over a Unix socket. Diode's services reach
PostgreSQL, Redis and Hydra over TCP inside a container network, so passwords
genuinely exist. What this script guarantees is that every one of them is born
on first boot, on this appliance, and that none of them is in the template.

diode.service and nginx.service are ordered after this and require it, so a
failure here leaves the appliance visibly down rather than half configured.
Re-run it with:

    systemctl start diode-bootstrap

With --reconcile (diode-reconcile.service, every subsequent boot) it only
re-derives the host names the appliance answers to, refreshes a generated
certificate and re-applies the outbound proxy; secrets, the databases and the
OAuth2 clients are never touched.
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
import subprocess
import sys
import traceback

STATE_DIR = '/var/lib/diode-appliance'
MARKER = os.path.join(STATE_DIR, 'bootstrapped')
FAILURE = os.path.join(STATE_DIR, 'failed')
STATE = os.path.join(STATE_DIR, 'state.json')

CONFIG_DIR = '/etc/diode'
PROJECT_DIR = os.path.join(CONFIG_DIR, 'compose')
ENV_TEMPLATE = os.path.join(CONFIG_DIR, 'env.template')
ENV_FILE = os.path.join(PROJECT_DIR, '.env')
CLIENTS_TEMPLATE = os.path.join(CONFIG_DIR, 'client-credentials.json.template')
CLIENTS_FILE = os.path.join(PROJECT_DIR, 'oauth2', 'client',
                            'client-credentials.json')
NETBOX_CA = os.path.join(CONFIG_DIR, 'netbox-ca.pem')

TLS_DIR = os.path.join(CONFIG_DIR, 'tls')
CERT = os.path.join(TLS_DIR, 'diode.crt')
KEY = os.path.join(TLS_DIR, 'diode.key')
SELF_SIGNED = os.path.join(TLS_DIR, '.self-signed')

AGENT_DIR = os.path.join(CONFIG_DIR, 'agent')
AGENT_TEMPLATE = os.path.join(AGENT_DIR, 'agent.yaml.template')
AGENT_CONFIG = os.path.join(AGENT_DIR, 'agent.yaml')
AGENT_CREDENTIALS = os.path.join(AGENT_DIR, 'credentials.env')

CREDENTIALS_FILE = '/root/diode-credentials.txt'
ISSUE_FILE = '/etc/issue.d/60-diode.issue'

SNIPPETS = '/etc/nginx/snippets'
OVF_SETTINGS = '/usr/local/sbin/ovf-settings.py'

DNS_NAME_RE = re.compile(
    r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*$')
PROXY_RE = re.compile(r'^https?://'
                      r'([^\s/@:]+(:[^\s/@]*)?@)?'
                      r'[A-Za-z0-9._\[\]:-]+'
                      r'(:[0-9]{1,5})?/?$')
UNSET_HOSTNAMES = ('localhost', 'localhost.localdomain', 'ubuntu', '')

# The three OAuth2 clients the stack bootstraps. Each gets its own generated
# secret: diode-ingest is what an agent or SDK authenticates as to push data,
# diode-to-netbox is what the reconciler uses to call the NetBox plugin, and
# netbox-to-diode is what the plugin uses to call back.
CLIENT_SECRETS = (
    ('__DIODE_INGEST_CLIENT_SECRET__', 'diode-ingest'),
    ('__DIODE_TO_NETBOX_CLIENT_SECRET__', 'diode-to-netbox'),
    ('__NETBOX_TO_DIODE_CLIENT_SECRET__', 'netbox-to-diode'),
)


def log(message):
    print('diode-firstboot: %s' % message, flush=True)


def run(command, **kwargs):
    kwargs.setdefault('check', True)
    kwargs.setdefault('text', True)
    return subprocess.run(command, **kwargs)


def capture(command, **kwargs):
    kwargs.setdefault('text', True)
    kwargs.setdefault('capture_output', True)
    result = subprocess.run(command, **kwargs)
    return result.stdout.strip() if result.returncode == 0 else ''


def compose(*args, check=True):
    """Run docker compose against the appliance's project directory."""
    return subprocess.run(['docker', 'compose'] + list(args),
                          cwd=PROJECT_DIR, text=True, check=check)


def is_dns_name(value):
    return bool(value) and len(value) <= 253 and bool(DNS_NAME_RE.match(value))


def generate_secret(length=32):
    return secrets.token_hex(length)


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


def truthy(value):
    return value.strip().lower() in ('true', 'yes', '1', 'on')


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
            if not address or entry.get('scope', '') in ('host', 'link'):
                continue
            addresses.append(address)
    return addresses


def resolve_identity(props):
    """Return (fqdn, addresses).

    The FQDN is what the certificate is issued for and what the operator is
    told to point agents at: the form's value if given, otherwise the guest's
    own name, otherwise its first address.
    """
    addresses = local_addresses()
    hostname = socket.gethostname()

    fqdn = prop(props, 'diode.fqdn') or prop(props, 'hostname')
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
        fqdn = '%s.%s' % (fqdn, domain[0])
    if not fqdn and addresses:
        fqdn = addresses[0]
    return fqdn, addresses


#
# Files
#

def write_file(path, content, mode, owner=None):
    """Write a file atomically with an explicit mode, never wider."""
    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, mode=0o750, exist_ok=True)
    temporary = '%s.tmp' % path
    with open(temporary, 'w') as handle:
        handle.write(content)
    os.chmod(temporary, mode)
    if owner:
        run(['chown', owner, temporary])
    os.replace(temporary, path)


def load_state():
    if not os.path.exists(STATE):
        return {}
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except ValueError:
        return {}


def save_state(state):
    write_file(STATE, json.dumps(state, indent=2, sort_keys=True) + '\n', 0o600)


#
# Compose environment
#

def netbox_plugin_url(raw):
    """Turn the deploy form's NetBox URL into the plugin API base URL.

    Operators type what they browse to - https://netbox.example.com - not the
    plugin's API path, and a trailing slash or an already-complete path are
    both things people will enter. Normalize rather than reject: getting this
    wrong means the reconciler retries forever against a 404, which looks like
    a Diode fault and is not one.
    """
    value = raw.strip().rstrip('/')
    if not value:
        return ''
    if not value.startswith(('http://', 'https://')):
        value = 'https://%s' % value
    suffix = '/api/plugins/diode'
    if value.endswith(suffix):
        return value
    return value + suffix


def render_environment(props, secrets_map):
    """Render the compose .env from the template shipped in the image."""
    with open(ENV_TEMPLATE) as handle:
        text = handle.read()

    netbox_url = netbox_plugin_url(prop(props, 'diode.netbox-url'))
    if not netbox_url:
        # Not fatal. An appliance with no target reconciles nothing, but it
        # still starts, still accepts ingest and can be pointed at a NetBox
        # afterwards - which is a far better first-boot outcome than a VM that
        # refuses to come up because one form field was left blank.
        log('no diode.netbox-url given; the reconciler will have no target'
            ' until one is set with diode-netbox')
        netbox_url = ''

    ca_pem = decode_pem(prop(props, 'diode.netbox-ca'), 'CA bundle')
    if ca_pem:
        write_file(NETBOX_CA, ca_pem, 0o644)
        ssl_cert_file = '/certs/ca.pem'
        log('trusting the supplied CA bundle for the NetBox connection')
    else:
        # Must stay empty rather than point at an empty file: Go ignores an
        # empty SSL_CERT_FILE and uses the system store, but an empty file
        # means an empty trust store and every connection fails.
        write_file(NETBOX_CA, '', 0o644)
        ssl_cert_file = ''

    skip_verify = 'true' if truthy(prop(props, 'diode.netbox-insecure')) else 'false'
    if skip_verify == 'true':
        log('WARNING: TLS verification of the NetBox connection is DISABLED'
            ' by the deploy form')

    replacements = {
        '__REDIS_PASSWORD__': secrets_map['redis'],
        '__POSTGRES_PASSWORD__': secrets_map['postgres'],
        '__DIODE_POSTGRES_PASSWORD__': secrets_map['diode_postgres'],
        '__HYDRA_POSTGRES_PASSWORD__': secrets_map['hydra_postgres'],
        '__HYDRA_SYSTEM_SECRET__': secrets_map['hydra_system'],
        '__DIODE_TO_NETBOX_CLIENT_SECRET__': secrets_map['diode-to-netbox'],
        '__NETBOX_PLUGIN_API_BASE_URL__': netbox_url,
        '__NETBOX_SKIP_TLS_VERIFY__': skip_verify,
        '__SSL_CERT_FILE__': ssl_cert_file,
    }
    for placeholder, value in replacements.items():
        text = text.replace(placeholder, value)

    leftover = re.findall(r'__[A-Z0-9_]+__', text)
    if leftover:
        raise SystemExit('diode-firstboot: unsubstituted placeholders in the'
                         ' compose environment: %s' % ', '.join(sorted(set(leftover))))

    write_file(ENV_FILE, text, 0o600)
    log('rendered %s' % ENV_FILE)


def render_clients(secrets_map):
    """Render the OAuth2 client credentials the auth bootstrap reads."""
    with open(CLIENTS_TEMPLATE) as handle:
        text = handle.read()
    for placeholder, client in CLIENT_SECRETS:
        text = text.replace(placeholder, secrets_map[client])
    # Validate before writing: a malformed file makes diode-auth-bootstrap
    # fail inside a container, which is a much worse place to read the error.
    json.loads(text)
    # TODO(scaffold): confirm the uid diode-auth and diode-reconciler run as.
    # The file is mounted read-only into both, and 0600 root works only if
    # they run as root. If they do not, this needs a dedicated group and 0640
    # rather than a wider mode. The build catches it either way: the stack
    # fails to come up and verify.sh fails the build.
    write_file(CLIENTS_FILE, text, 0o600)
    log('rendered %s' % CLIENTS_FILE)


#
# TLS
#

def decode_pem(value, label):
    """Decode a base64 deploy-form field into PEM text, or return ''."""
    if not value:
        return ''
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        # Tolerate a PEM pasted directly: people do it, and refusing is worse
        # than accepting something that is unambiguously already PEM.
        if '-----BEGIN' in value:
            return value if value.endswith('\n') else value + '\n'
        log('ignoring the %s from the deploy form: not valid base64' % label)
        return ''
    try:
        text = raw.decode('ascii')
    except UnicodeDecodeError:
        log('ignoring the %s from the deploy form: not ASCII PEM' % label)
        return ''
    if '-----BEGIN' not in text:
        log('ignoring the %s from the deploy form: no PEM block' % label)
        return ''
    return text if text.endswith('\n') else text + '\n'


def install_operator_certificate(props):
    """Install a certificate and key supplied on the deploy form."""
    cert = decode_pem(prop(props, 'diode.tls-cert'), 'TLS certificate')
    key = decode_pem(prop(props, 'diode.tls-key'), 'TLS private key')
    if not cert or not key:
        if cert or key:
            log('ignoring the deploy form TLS material: both a certificate'
                ' and a matching key are required')
        return False
    write_file(CERT, cert, 0o644)
    write_file(KEY, key, 0o640, owner='root:www-data')
    if os.path.exists(SELF_SIGNED):
        os.unlink(SELF_SIGNED)
    log('installed the operator-supplied TLS certificate')
    return True


def generate_certificate(fqdn, addresses):
    """Issue the appliance's own self-signed certificate.

    The marker file is what tells diode-reconcile this certificate is the
    appliance's own and may be reissued when the address changes. An operator
    certificate installed later removes it - see diode-tls.
    """
    names = []
    for candidate in [fqdn, socket.gethostname(), 'localhost']:
        if candidate and candidate not in names:
            names.append(candidate)
    ips = ['127.0.0.1', '::1']
    for address in addresses:
        try:
            ipaddress.ip_address(address.split('/')[0])
        except ValueError:
            continue
        if address.split('/')[0] not in ips:
            ips.append(address.split('/')[0])

    san = ','.join(['DNS:%s' % n for n in names if not _is_ip(n)] +
                   ['IP:%s' % i for i in ips])
    os.makedirs(TLS_DIR, mode=0o755, exist_ok=True)
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-sha256',
         '-days', '3650', '-nodes',
         '-keyout', KEY, '-out', CERT,
         '-subj', '/CN=%s' % (fqdn or socket.gethostname()),
         '-addext', 'subjectAltName=%s' % san],
        capture_output=True)
    os.chmod(CERT, 0o644)
    os.chmod(KEY, 0o640)
    run(['chown', 'root:www-data', KEY])
    write_file(SELF_SIGNED, 'generated by diode-firstboot\n', 0o644)
    log('issued a self-signed certificate for %s' % san)


def _is_ip(value):
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


#
# nginx
#

def parse_allowlist(value):
    """Plain addresses and CIDRs only, from the metrics-allow form field."""
    entries = []
    for raw in re.split(r'[\s,]+', value or ''):
        candidate = raw.strip()
        if not candidate:
            continue
        try:
            ipaddress.ip_network(candidate, strict=False)
        except ValueError:
            log('ignoring %r in the metrics allowlist: not an address or CIDR'
                % candidate)
            continue
        entries.append(candidate)
    return entries


def write_nginx_snippets(fqdn, metrics_allow, operator_certificate):
    server_name = fqdn if is_dns_name(fqdn) else '_'
    write_file(os.path.join(SNIPPETS, 'diode-server-name.conf'),
               '# Written by diode-firstboot.py.\nserver_name %s;\n'
               % server_name, 0o644)

    allow = parse_allowlist(metrics_allow)
    if allow:
        body = ''.join('allow %s;\n' % entry for entry in allow) + 'deny all;\n'
    else:
        body = 'deny all;\n'
    write_file(os.path.join(SNIPPETS, 'diode-metrics.conf'),
               '# Written by diode-firstboot.py.\n' + body, 0o644)

    # HSTS only with an operator certificate: with the generated self-signed
    # one it would make the browser warning impossible to click through.
    hsts = ('add_header Strict-Transport-Security "max-age=31536000;'
            ' includeSubDomains" always;\n' if operator_certificate else '')
    write_file(os.path.join(SNIPPETS, 'diode-hsts.conf'),
               '# Written by diode-firstboot.py.\n' + hsts, 0o644)

    if allow:
        run(['systemctl', 'enable', '--now', 'prometheus-node-exporter'],
            check=False)
    else:
        run(['systemctl', 'disable', '--now', 'prometheus-node-exporter'],
            check=False)


#
# Outbound proxy
#

def write_proxy(props):
    """Apply the deploy form's proxy to everything on this appliance.

    Four places, because none of them reads the others: /etc/environment for
    login sessions, apt.conf for unattended-upgrades, a systemd drop-in on
    docker.service so image pulls go through it, and the Docker client
    configuration so containers inherit it.

    TODO(scaffold): lift the validation, redaction and bypass-list handling
    from Appliances/netbox/files/netbox-appliance/netbox-firstboot.py rather
    than reimplementing them - the parsing rules there (refuse a value that
    could terminate one of the three quoting contexts instead of escaping it
    three ways) apply unchanged here, and the two copies must not drift.
    """
    url = prop(props, 'diode.proxy')
    if url and not PROXY_RE.match(url):
        log('ignoring the proxy from the deploy form: %r is not'
            ' http://host[:port]' % re.sub(r'//[^@]*@', '//***@', url))
        url = ''
    log('proxy configuration is not implemented in this scaffold'
        if url else 'no outbound proxy configured')


def apply_time_zone(props):
    """Set the host time zone from the deploy form.

    The containers keep their own clocks in UTC and nothing here changes that.
    What this fixes is the thing an operator actually reads: journal, nginx
    and diode-status timestamps in local time, on an appliance whose logs are
    usually the only evidence of what happened at a site nobody can reach.
    """
    zone = prop(props, 'diode.time-zone')
    if not zone:
        return
    if not re.match(r'^[A-Za-z][A-Za-z0-9+_-]*(/[A-Za-z0-9+_.-]+)*$', zone):
        log('ignoring the time zone from the deploy form: %r is not an IANA'
            ' zone name' % zone)
        return
    if not os.path.exists(os.path.join('/usr/share/zoneinfo', zone)):
        log('ignoring the time zone from the deploy form: %r is not installed'
            % zone)
        return
    run(['timedatectl', 'set-timezone', zone], check=False)
    log('time zone set to %s' % zone)


#
# Discovery agent
#

def configure_agent(props, ingest_secret):
    """Render agent.yaml and enable the agent, if the deploy form asked for it.

    Off unless agent.enabled is set. The agent belongs near the devices it
    discovers, which for a multi-site customer is not this VM; on-box is the
    single-site convenience, not the recommendation.
    """
    if not truthy(prop(props, 'agent.enabled')):
        log('discovery agent not enabled')
        return False

    targets = [t for t in re.split(r'[\s,]+', prop(props, 'agent.targets'))
               if t.strip()]
    if not targets:
        log('agent.enabled is set but agent.targets is empty; not starting an'
            ' agent with nothing to scan')
        return False

    with open(AGENT_TEMPLATE) as handle:
        text = handle.read()
    rendered_targets = '\n'.join('            - %s' % t for t in targets)
    text = text.replace('__AGENT_TARGETS__', rendered_targets)
    text = text.replace('__AGENT_NAME__', socket.gethostname() or 'diode-appliance')
    write_file(AGENT_CONFIG, text, 0o640)

    # The agent authenticates as the diode-ingest client, the same identity an
    # off-box agent would use. Keeping it in a 0600 environment file rather
    # than in agent.yaml means the config file can be read, diffed and backed
    # up without carrying the secret.
    write_file(AGENT_CREDENTIALS,
               '# Written by diode-firstboot.py.\n'
               'DIODE_CLIENT_ID=diode-ingest\n'
               'DIODE_CLIENT_SECRET=%s\n' % ingest_secret, 0o600)

    run(['systemctl', 'enable', 'diode-agent.service'], check=False)
    log('discovery agent enabled for %d target(s)' % len(targets))
    return True


#
# Credentials
#

def write_credentials(state, secrets_map, agent_enabled):
    """Record what an operator needs, where they can actually reach it.

    A freshly deployed appliance may have no other way in, so this goes to
    /root (0600) and to the LOCAL console banner - never to /etc/issue.net,
    which the hardened base uses as the pre-authentication SSH banner.
    """
    lines = [
        'NetBox Diode appliance',
        '',
        'Ingestion endpoint : grpc://%s:443/diode' % (state.get('fqdn') or '<address>'),
        'OAuth2 client      : diode-ingest',
        'OAuth2 secret      : %s' % secrets_map['diode-ingest'],
        '',
        'The NetBox side needs the netbox-to-diode client:',
        '  client id        : netbox-to-diode',
        '  client secret    : %s' % secrets_map['netbox-to-diode'],
        '',
        'Clear this file once the values are stored elsewhere:',
        '  diode-credentials --clear',
        '',
    ]
    if agent_enabled:
        lines.insert(3, 'On-box discovery agent : enabled')
    write_file(CREDENTIALS_FILE, '\n'.join(lines), 0o600)
    write_file(ISSUE_FILE,
               '\nDiode ingest client "diode-ingest" secret is in'
               ' /root/diode-credentials.txt\n\n', 0o644)


#
# Bootstrap and reconcile
#

def bootstrap(props):
    log('bootstrapping the appliance')
    os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)

    fqdn, addresses = resolve_identity(props)
    log('identity: fqdn=%s addresses=%s' % (fqdn or '<none>',
                                            ', '.join(addresses) or '<none>'))

    secrets_map = {
        'redis': generate_secret(),
        'postgres': generate_secret(),
        'diode_postgres': generate_secret(),
        'hydra_postgres': generate_secret(),
        'hydra_system': generate_secret(),
        'diode-ingest': generate_secret(),
        'diode-to-netbox': generate_secret(),
        'netbox-to-diode': generate_secret(),
    }

    apply_time_zone(props)
    render_environment(props, secrets_map)
    render_clients(secrets_map)
    write_proxy(props)

    operator_certificate = install_operator_certificate(props)
    if not operator_certificate:
        generate_certificate(fqdn, addresses)
    write_nginx_snippets(fqdn, prop(props, 'diode.metrics-allow'),
                         operator_certificate)

    agent_enabled = configure_agent(props, secrets_map['diode-ingest'])

    state = {
        'fqdn': fqdn,
        'addresses': addresses,
        'operator_certificate': operator_certificate,
        'agent_enabled': agent_enabled,
        'bootstrapped_at': datetime.datetime.now(
            datetime.timezone.utc).isoformat(timespec='seconds'),
    }
    save_state(state)
    write_credentials(state, secrets_map, agent_enabled)

    log('starting the Diode stack')
    compose('up', '--detach', '--wait', '--wait-timeout', '300')

    write_file(MARKER, 'bootstrapped\n', 0o644)
    log('bootstrap complete')


def reconcile(props):
    """Re-derive what the address may have changed under us. Nothing else."""
    state = load_state()
    fqdn, addresses = resolve_identity(props)
    changed = (fqdn != state.get('fqdn') or
               addresses != state.get('addresses', []))

    write_proxy(props)

    if not changed:
        log('identity unchanged (%s)' % (fqdn or '<none>'))
        return

    log('identity changed: %s -> %s' % (state.get('fqdn') or '<none>',
                                        fqdn or '<none>'))
    if os.path.exists(SELF_SIGNED):
        generate_certificate(fqdn, addresses)
    else:
        log('leaving the operator-supplied certificate in place')
    write_nginx_snippets(fqdn, prop(props, 'diode.metrics-allow'),
                         not os.path.exists(SELF_SIGNED))
    run(['systemctl', 'reload-or-restart', 'nginx'], check=False)

    state['fqdn'] = fqdn
    state['addresses'] = addresses
    save_state(state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reconcile', action='store_true',
                        help='re-derive addresses and certificates only')
    args = parser.parse_args()

    if os.geteuid() != 0:
        sys.exit('diode-firstboot: must run as root')

    props = ovf_properties()
    try:
        if args.reconcile:
            reconcile(props)
        else:
            bootstrap(props)
    except Exception:
        os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
        write_file(FAILURE, traceback.format_exc(), 0o600)
        raise


if __name__ == '__main__':
    main()
