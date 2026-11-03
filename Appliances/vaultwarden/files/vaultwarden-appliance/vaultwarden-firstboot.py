#!/usr/bin/env python3
"""Bootstrap and reconcile a Vaultwarden appliance from the vSphere deploy form.

The exported template carries no secret and no identity: no admin token, no
TLS key, no database, no RSA signing key, no machine id. This runs once on the
first boot of a deployment and creates what Vaultwarden needs, taking whatever
the operator filled into the deploy form and generating the rest. Leaving the
whole form empty is supported: the appliance then serves a self-signed
certificate on its own name, and the generated admin token is printed on the VM
console and written to /root/vaultwarden-credentials.txt.

vaultwarden.service and nginx.service are ordered after this and require it, so
a failure here leaves the appliance visibly down rather than half configured.
Re-run it with:

    systemctl start vaultwarden-bootstrap

With --reconcile (vaultwarden-reconcile.service, every subsequent boot) it
re-reads the deploy form and re-applies everything that is configuration -
the name, the settings, the allowlists, the firewall, the proxy, a generated
certificate. It never generates a secret, never touches the database or the
data directory, and an empty secret field never clears a stored secret.
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
import uuid

STATE_DIR = '/var/lib/vaultwarden-appliance'
MARKER = os.path.join(STATE_DIR, 'bootstrapped')
FAILURE = os.path.join(STATE_DIR, 'failed')
STATE = os.path.join(STATE_DIR, 'state.json')
INITIALIZED = os.path.join(STATE_DIR, 'initialized')
FIREWALL_STATE = os.path.join(STATE_DIR, 'firewall.json')

CONFIG_DIR = '/etc/vaultwarden'
ENV_FILE = os.path.join(CONFIG_DIR, 'vaultwarden.env')
COMPOSE_ENV = os.path.join(CONFIG_DIR, '.env')
SECRETS_DIR = os.path.join(CONFIG_DIR, 'secrets')
VOLUME_ID = os.path.join(CONFIG_DIR, 'volume-id')
TLS_DIR = os.path.join(CONFIG_DIR, 'tls')
CERT = os.path.join(TLS_DIR, 'vaultwarden.crt')
KEY = os.path.join(TLS_DIR, 'vaultwarden.key')
SELF_SIGNED = os.path.join(TLS_DIR, '.self-signed')

DATA_ROOT = '/srv/vaultwarden'
DATA_DIR = os.path.join(DATA_ROOT, 'data')
BACKUP_DIR = os.path.join(DATA_ROOT, 'backups')
DATA_VOLUME_ID = os.path.join(DATA_ROOT, '.volume-id')
PG_SOCKET_DIR = '/run/postgresql'

CREDENTIALS = '/root/vaultwarden-credentials.txt'
ISSUE = '/etc/issue.d/60-vaultwarden.issue'
CGROUP = '/proc/self/cgroup'
OVF_SETTINGS = '/usr/local/sbin/ovf-settings.py'

SNIPPET_SERVER_NAME = '/etc/nginx/snippets/vaultwarden-server-name.conf'
SNIPPET_ADMIN = '/etc/nginx/snippets/vaultwarden-admin.conf'
SNIPPET_HSTS = '/etc/nginx/snippets/vaultwarden-hsts.conf'

# Container-side paths of the secret files; SECRETS_DIR is bind-mounted there
# read-only. Vaultwarden reads <KEY>_FILE and trims the content, so secrets
# never sit in the container environment, where `docker inspect` shows them.
CONTAINER_SECRETS = '/run/secrets'
SECRET_ADMIN_TOKEN = 'admin_token'
SECRET_SMTP_PASSWORD = 'smtp_password'
SECRET_SSO_CLIENT_SECRET = 'sso_client_secret'

UNSET_HOSTNAMES = {'', 'localhost', 'localhost.localdomain', '(none)'}

# Deploy-form values end up in nginx directives, certificate SANs, ufw rules
# and the container environment, so they are untrusted input to four parsers.
# Anything that is not plainly valid is dropped rather than escaped.
DNS_NAME_RE = re.compile(
    r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))*\.?$')
EMAIL_RE = re.compile(r'^[A-Za-z0-9.!#%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$')
# What may appear inside a single-quoted value of the env file: Compose takes
# single-quoted values literally, so the only characters that must never
# appear are the quote itself and line breaks. Secrets do not go through this
# at all - they are files.
SAFE_ENV_VALUE_RE = re.compile(r"^[^'\r\n\x00]*$")
ARGON2_PHC_RE = re.compile(r'^\$argon2id\$v=19\$m=\d+,t=\d+,p=\d+\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$')
SMTP_SECURITY = {'starttls': '587', 'force_tls': '465', 'off': '25'}
TIME_ZONE_RE = re.compile(r'^[A-Za-z][A-Za-z0-9_+/-]{0,63}$')

# OWASP's 2023 Argon2id recommendation and what upstream's wiki uses for
# ADMIN_TOKEN: 64 MiB, three passes, four lanes.
ARGON2_ARGS = ['-id', '-t', '3', '-k', '65540', '-p', '4', '-e']


def is_dns_name(value):
    return bool(value) and len(value) <= 253 and bool(DNS_NAME_RE.match(value))


def is_address(value):
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def log(message):
    print('vaultwarden-firstboot: %s' % message, flush=True)


def run(command, **kwargs):
    kwargs.setdefault('check', True)
    kwargs.setdefault('text', True)
    return subprocess.run(command, **kwargs)


def capture(command, **kwargs):
    kwargs.setdefault('text', True)
    kwargs.setdefault('capture_output', True)
    result = subprocess.run(command, **kwargs)
    return result.stdout.strip() if result.returncode == 0 else ''


#
# Deploy form
#

def ovf_properties():
    """Read the OVF environment using the base image's own parser."""
    if not os.path.exists(OVF_SETTINGS):
        log('%s is missing; every value falls back to a default' % OVF_SETTINGS)
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
                ' default')
            return {}
        return module.parse_props(xml_text)
    except Exception as exc:
        log('could not read the OVF environment (%s); every value falls back'
            ' to a default' % exc)
        return {}
    finally:
        sys.argv = saved_argv


def prop(props, key, default=''):
    return (props.get(key) or '').strip() or default


def split_list(value):
    return [entry for entry in re.split(r'[,\s]+', value or '') if entry]


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
            if address and entry.get('scope', '') not in ('host', 'link'):
                addresses.append(address)
    return addresses


def resolve_identity(props, hostname=None, fqdn_lookup=None, addresses=None):
    """Return (fqdn, addresses).

    The FQDN is what DOMAIN, the certificate and nginx's server_name are
    derived from: the form's value if given, otherwise the guest's own name,
    otherwise its first address. The lookups are injectable for the tests.
    """
    addresses = local_addresses() if addresses is None else addresses
    hostname = socket.gethostname() if hostname is None else hostname
    fqdn_lookup = fqdn_lookup or socket.getfqdn

    fqdn = prop(props, 'vaultwarden.fqdn') or prop(props, 'hostname')
    if fqdn and not is_dns_name(fqdn):
        log('ignoring %r from the deploy form: not a valid host name' % fqdn)
        fqdn = ''
    if not fqdn and hostname.lower() not in UNSET_HOSTNAMES:
        resolved = fqdn_lookup()
        candidate = (resolved if resolved.lower() not in UNSET_HOSTNAMES
                     else hostname)
        fqdn = candidate if is_dns_name(candidate) else ''
    domain = split_list(prop(props, 'network.domain'))
    if fqdn and '.' not in fqdn and domain:
        qualified = '%s.%s' % (fqdn, domain[0])
        if is_dns_name(qualified):
            fqdn = qualified
    fqdn = fqdn.rstrip('.').lower()
    if not fqdn and addresses:
        fqdn = addresses[0]
    return fqdn, addresses


def domain_url(fqdn):
    """DOMAIN as Vaultwarden wants it: scheme, host, no trailing slash.

    It is also the WebAuthn relying-party id, so changing it later orphans
    every registered FIDO2 key - the README says so loudly.
    """
    if not fqdn:
        return 'https://localhost'
    if ':' in fqdn:
        return 'https://[%s]' % fqdn
    return 'https://%s' % fqdn


#
# Allowlists
#

def parse_networks(value, field):
    """Addresses and networks, normalized; anything else is dropped."""
    entries = []
    for entry in split_list(value):
        try:
            network = ipaddress.ip_network(entry, strict=False)
        except ValueError:
            log('ignoring %r in %s: not an address or CIDR' % (entry, field))
            continue
        text = str(network)
        if text not in entries:
            entries.append(text)
    return entries


def allowlist(props, key):
    """(entries, invalid): invalid is True when the field was filled in but
    nothing in it parsed.

    That case must not look like an empty field: an empty vaultwarden.https-
    allow means "from anywhere" on purpose, while `10.0.0.0/33` means someone
    tried to restrict it and mistyped. The callers fail closed on it.
    """
    raw = prop(props, key)
    entries = parse_networks(raw, key)
    invalid = bool(raw) and not entries
    if invalid:
        log('%s is set but contains no valid address or CIDR' % key)
    return entries, invalid


def parse_emails(value, field):
    entries = []
    for entry in split_list(value):
        if EMAIL_RE.match(entry) and len(entry) <= 254:
            if entry.lower() not in entries:
                entries.append(entry.lower())
        else:
            log('ignoring %r in %s: not an email address' % (entry, field))
    return entries


#
# Settings
#

def smtp_settings(props):
    """The SMTP half of the environment, or {} when SMTP is not configured."""
    host = prop(props, 'vaultwarden.smtp-host')
    if not host:
        return {}
    if not (is_dns_name(host) or is_address(host)):
        log('ignoring vaultwarden.smtp-host %r: not a host name or address'
            % host)
        return {}
    security = prop(props, 'vaultwarden.smtp-security', 'starttls').lower()
    if security not in SMTP_SECURITY:
        log('ignoring vaultwarden.smtp-security %r: expected starttls,'
            ' force_tls or off; using starttls' % security)
        security = 'starttls'
    port = prop(props, 'vaultwarden.smtp-port', SMTP_SECURITY[security])
    if not port.isdigit() or not 0 < int(port) < 65536:
        log('ignoring vaultwarden.smtp-port %r; using %s'
            % (port, SMTP_SECURITY[security]))
        port = SMTP_SECURITY[security]
    sender = prop(props, 'vaultwarden.smtp-from')
    if not EMAIL_RE.match(sender):
        # Vaultwarden refuses to start with SMTP_HOST and no valid SMTP_FROM,
        # which would take the whole appliance down over a mail setting.
        log('vaultwarden.smtp-host is set but vaultwarden.smtp-from %r is not'
            ' an email address; SMTP stays off' % sender)
        return {}
    settings = {
        'SMTP_HOST': host,
        'SMTP_PORT': port,
        'SMTP_SECURITY': security,
        'SMTP_FROM': sender,
        'SMTP_FROM_NAME': 'Vaultwarden',
        'SMTP_TIMEOUT': '15',
    }
    username = prop(props, 'vaultwarden.smtp-username')
    if username:
        settings['SMTP_USERNAME'] = username
    return settings


def parse_bool(value, field, default=False):
    text = (value or '').strip().lower()
    if not text:
        return default
    if text in ('true', 'yes', 'on', '1'):
        return True
    if text in ('false', 'no', 'off', '0'):
        return False
    log('ignoring %s %r: expected true or false' % (field, value))
    return default


# What an OIDC scope may look like; "openid" is implied by Vaultwarden.
SCOPE_RE = re.compile(r'^[A-Za-z0-9._:/-]{1,64}$')
# offline_access: without it the IdP returns no refresh token and an SSO
# session ends with the access token. Entra ID and Keycloak both want it.
DEFAULT_SSO_SCOPES = 'openid profile email offline_access'


def sso_settings(props, have_secret):
    """OpenID Connect, off unless authority, client id AND secret are set.

    Vaultwarden refuses to start with SSO_ENABLED and any of the three
    missing (validate_config), which would take the whole appliance down
    over an incomplete SSO form - so an incomplete set means SSO off.
    """
    authority = prop(props, 'vaultwarden.sso-authority')
    client_id = prop(props, 'vaultwarden.sso-client-id')
    if not authority and not client_id:
        return {'SSO_ENABLED': 'false'}
    if not authority.startswith('https://') or not client_id:
        log('vaultwarden.sso-authority must be an https:// URL and'
            ' vaultwarden.sso-client-id must be set; SSO stays off')
        return {'SSO_ENABLED': 'false'}
    if not have_secret(SECRET_SSO_CLIENT_SECRET):
        log('vaultwarden.sso-client-secret has never been supplied; SSO stays'
            ' off until it is')
        return {'SSO_ENABLED': 'false'}

    scopes = split_list(prop(props, 'vaultwarden.sso-scopes',
                             DEFAULT_SSO_SCOPES))
    scopes = [scope for scope in scopes if SCOPE_RE.match(scope)]
    if not scopes:
        scopes = DEFAULT_SSO_SCOPES.split()
    return {
        'SSO_ENABLED': 'true',
        # Local master-password login stays available: SSO in Vaultwarden
        # authenticates, it does not unlock the vault, and an IdP outage must
        # not lock everyone out of their passwords. Flip it in /admin if ever
        # wanted, once SSO is proven.
        'SSO_ONLY': 'false',
        'SSO_AUTHORITY': authority.rstrip('/'),
        'SSO_CLIENT_ID': client_id,
        'SSO_CLIENT_SECRET_FILE': '%s/%s' % (CONTAINER_SECRETS,
                                             SECRET_SSO_CLIENT_SECRET),
        'SSO_SCOPES': ' '.join(scopes),
        'SSO_PKCE': 'true',
        # Link an SSO login to the existing local account with the same
        # address, so users invited before SSO keep their vault.
        'SSO_SIGNUPS_MATCH_EMAIL': 'true',
        # Off by default, like SIGNUPS_ALLOWED: a first SSO login creates an
        # account only for an address that was invited. Turn it on once the
        # IdP side decides who may use the app (Entra "assignment required").
        'SSO_SIGNUPS_ALLOWED': 'true' if parse_bool(
            prop(props, 'vaultwarden.sso-signups-allowed'),
            'vaultwarden.sso-signups-allowed') else 'false',
        # Entra ID sends no email_verified claim at all, and Vaultwarden then
        # refuses every SSO login unless told the status may be unknown.
        'SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION': 'true' if parse_bool(
            prop(props, 'vaultwarden.sso-allow-unknown-email-verification'),
            'vaultwarden.sso-allow-unknown-email-verification') else 'false',
    }


def build_settings(props, fqdn, have_secret):
    """The container environment, as an ordered dict of plain strings.

    have_secret(name) says whether a secret file exists, so the matching
    <KEY>_FILE variable is only set when Vaultwarden can actually read it -
    a _FILE pointing at nothing is a startup panic.
    """
    smtp = smtp_settings(props)
    org_creators = parse_emails(prop(props, 'vaultwarden.org-creators'),
                                'vaultwarden.org-creators')
    time_zone = prop(props, 'vaultwarden.time-zone', 'UTC')
    if not TIME_ZONE_RE.match(time_zone):
        log('ignoring vaultwarden.time-zone %r; using UTC' % time_zone)
        time_zone = 'UTC'
    settings = {
        'DOMAIN': domain_url(fqdn),
        'TZ': time_zone,

        # Loopback only: nginx is the one thing allowed to reach it.
        'ROCKET_ADDRESS': '127.0.0.1',
        'ROCKET_PORT': '8000',
        'IP_HEADER': 'X-Real-IP',
        'IP_HEADER_TRUSTED_PROXIES': 'local',

        # Peer authentication over the bind-mounted socket: no password.
        'DATABASE_URL': 'postgresql://vaultwarden@/vaultwarden?host=%s'
                        % PG_SOCKET_DIR,
        'DATABASE_MAX_CONNS': '10',
        'DB_CONNECTION_RETRIES': '30',
        'DATA_FOLDER': '/data',

        # Accounts exist only by invitation. Email verification is only
        # required when there is a mail server to send the verification;
        # without SMTP it would lock every invited user out.
        'SIGNUPS_ALLOWED': 'false',
        'SIGNUPS_VERIFY': 'true' if smtp else 'false',
        'INVITATIONS_ALLOWED': 'true',
        'INVITATION_ORG_NAME': 'Vaultwarden',
        'ORG_CREATION_USERS': ','.join(org_creators) if org_creators else 'none',
        'EMERGENCY_ACCESS_ALLOWED': 'true',
        'SENDS_ALLOWED': 'true',
        'PASSWORD_HINTS_ALLOWED': 'false',
        'SHOW_PASSWORD_HINT': 'false',
        'ORG_EVENTS_ENABLED': 'true',
        'EVENTS_DAYS_RETAIN': '365',

        'ENABLE_WEBSOCKET': 'true',
        'WEB_VAULT_ENABLED': 'true',
        # The icon fetcher is a server-side HTTP client driven by URLs users
        # type in; this keeps it from being pointed at internal addresses.
        'HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS': 'true',

        'LOGIN_RATELIMIT_SECONDS': '60',
        'LOGIN_RATELIMIT_MAX_BURST': '10',
        'ADMIN_RATELIMIT_SECONDS': '300',
        'ADMIN_RATELIMIT_MAX_BURST': '3',
        'ADMIN_SESSION_LIFETIME': '20',

        # warn, not info: at info Vaultwarden logs every request line, and a
        # few endpoints carry tokens in the query string. Failed logins and
        # bad admin tokens are logged at error, so fail2ban still sees them.
        'LOG_LEVEL': 'warn',
        'EXTENDED_LOGGING': 'true',
    }
    settings.update(smtp)
    settings.update(sso_settings(props, have_secret))
    settings.update(proxy_environment(props))

    if have_secret(SECRET_ADMIN_TOKEN):
        settings['ADMIN_TOKEN_FILE'] = '%s/%s' % (CONTAINER_SECRETS,
                                                 SECRET_ADMIN_TOKEN)
    if smtp and have_secret(SECRET_SMTP_PASSWORD):
        settings['SMTP_PASSWORD_FILE'] = '%s/%s' % (CONTAINER_SECRETS,
                                                   SECRET_SMTP_PASSWORD)
    return settings


def render_env(settings):
    """The Compose env_file. Every value single-quoted, i.e. literal.

    A value that cannot be single-quoted safely is dropped with a log line
    rather than escaped: Compose has no escape inside single quotes, and a
    broken env file would stop the appliance from starting at all.
    """
    lines = ['# Written by vaultwarden-firstboot.py from the deploy form.',
             '# Rewritten on every boot; edit the vApp properties instead.',
             '# Secrets are not here: see the *_FILE entries.']
    for key, value in settings.items():
        value = str(value)
        if not SAFE_ENV_VALUE_RE.match(value):
            log('dropping %s: the value contains a quote or line break' % key)
            continue
        lines.append("%s='%s'" % (key, value))
    return '\n'.join(lines) + '\n'


#
# Secrets
#

def secret_path(name):
    return os.path.join(SECRETS_DIR, name)


def have_secret(name):
    return os.path.exists(secret_path(name))


def write_secret(name, value):
    """0440 root:vaultwarden, no trailing newline (Vaultwarden trims anyway)."""
    os.makedirs(SECRETS_DIR, mode=0o750, exist_ok=True)
    run(['chown', 'root:vaultwarden', SECRETS_DIR])
    os.chmod(SECRETS_DIR, 0o750)
    write_file(secret_path(name), value, 0o440, 'root:vaultwarden')


def hash_admin_token(token):
    salt = base64.b64encode(secrets.token_bytes(16)).decode().rstrip('=')
    result = subprocess.run(['argon2', salt] + ARGON2_ARGS, input=token,
                            text=True, capture_output=True, check=True)
    phc = result.stdout.strip()
    if not ARGON2_PHC_RE.match(phc):
        raise RuntimeError('argon2 produced an unexpected hash format')
    return phc


def apply_secrets(props, first_boot):
    """Write secrets from the form; generate the admin token on first boot.

    Returns the plaintext admin token when one was generated, else ''. An
    empty form field never removes a stored secret: the README tells operators
    to clear secret vApp properties after deployment, and that must not
    silently turn SMTP or SSO off on the next boot.
    """
    generated = ''
    # The admin token is seeded at first boot only. Day-two changes are made
    # with vaultwarden-admin-token (rotate, disable), and a reconcile must not
    # write the form's original hash back over them - or `rotate` would print
    # a token that cannot log in while the old one keeps working, and
    # `disable` would quietly re-enable the page.
    if first_boot:
        supplied_hash = prop(props, 'vaultwarden.admin-token-hash')
        if supplied_hash and not ARGON2_PHC_RE.match(supplied_hash):
            # A plaintext token here would be stored and compared as-is; the
            # field exists for an argon2id hash only.
            log('ignoring vaultwarden.admin-token-hash: not an argon2id PHC'
                ' string (generate one with `vaultwarden-admin-token hash`)')
            supplied_hash = ''
        if supplied_hash:
            write_secret(SECRET_ADMIN_TOKEN, supplied_hash)
        else:
            # Generated afresh on every bootstrap attempt, not only when no
            # hash exists yet: the plaintext is handed to the operator only
            # once the whole bootstrap has succeeded, so a hash left behind
            # by an attempt that failed later (a bad TLS pair, say) belongs
            # to a token nobody ever saw.
            generated = secrets.token_urlsafe(32)
            write_secret(SECRET_ADMIN_TOKEN, hash_admin_token(generated))
            log('generated the admin token')

    for field, name in (('vaultwarden.smtp-password', SECRET_SMTP_PASSWORD),
                        ('vaultwarden.sso-client-secret',
                         SECRET_SSO_CLIENT_SECRET)):
        value = prop(props, field)
        if value:
            write_secret(name, value)
    return generated


#
# Data disk and database
#

def ensure_volume():
    """Tie this deployment to its data disk, adopting an existing one.

    vaultwarden-guard refuses to start Vaultwarden unless the id on the
    mounted disk matches the copy on the root disk, so a missing, blank or
    swapped disk is a refusal to start rather than a fresh empty instance.
    A disk that already carries an id - an existing data disk attached to a
    fresh deployment, the recovery case - is adopted as it is.
    """
    mounted = subprocess.run(['findmnt', '--noheadings', '--mountpoint',
                              DATA_ROOT], capture_output=True)
    if mounted.returncode != 0:
        raise RuntimeError('%s is not mounted; refusing to initialize on the'
                           ' root disk' % DATA_ROOT)
    if os.path.exists(DATA_VOLUME_ID):
        with open(DATA_VOLUME_ID) as handle:
            volume = handle.read().strip()
        log('adopting the existing data disk %s' % volume)
        adopted = True
    else:
        volume = str(uuid.uuid4())
        write_file(DATA_VOLUME_ID, volume + '\n', 0o644)
        adopted = False
    write_file(VOLUME_ID, volume + '\n', 0o644)

    for path, mode, owner in ((DATA_DIR, 0o700, 'vaultwarden:vaultwarden'),
                              (BACKUP_DIR, 0o700, 'root:root')):
        os.makedirs(path, exist_ok=True)
        os.chmod(path, mode)
        run(['chown', owner, path])
    return volume, adopted


def psql(sql, database='postgres'):
    return capture(['runuser', '-u', 'postgres', '--', 'psql', '-X', '-q',
                    '-v', 'ON_ERROR_STOP=1', '-tA', '-d', database, '-c', sql])


def ensure_database():
    """Create the role and database if missing. Never drops anything."""
    run(['pg_isready', '-q', '-t', '60', '-h', PG_SOCKET_DIR])
    if psql("SELECT 1 FROM pg_roles WHERE rolname = 'vaultwarden'") != '1':
        run(['runuser', '-u', 'postgres', '--', 'psql', '-X', '-q',
             '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE ROLE vaultwarden LOGIN'])
        log('created the vaultwarden role')
    if psql("SELECT 1 FROM pg_database WHERE datname = 'vaultwarden'") != '1':
        run(['runuser', '-u', 'postgres', '--', 'createdb',
             '--owner=vaultwarden', '--encoding=UTF8', '--locale=C.UTF-8',
             '--template=template0', 'vaultwarden'])
        log('created the vaultwarden database')
        return False
    has_schema = psql("SELECT to_regclass('public.__diesel_schema_migrations')"
                      " IS NOT NULL", 'vaultwarden') == 't'
    if has_schema:
        log('the vaultwarden database already holds a schema; keeping it')
    return has_schema


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

    A supplied-but-broken pair fails the bootstrap on purpose: Bitwarden
    clients refuse an untrusted certificate, so quietly serving a self-signed
    one where a real one was asked for would just move the failure to every
    user's device.
    """
    cert_value = prop(props, 'vaultwarden.tls-cert')
    key_value = prop(props, 'vaultwarden.tls-key')
    if not cert_value and not key_value:
        return False
    if not cert_value or not key_value:
        raise RuntimeError('vaultwarden.tls-cert and vaultwarden.tls-key must'
                           ' be given together')
    write_file(CERT, decode_pem(cert_value, 'vaultwarden.tls-cert'), 0o644,
               'root:root')
    # nginx's master process reads the key as root; the workers never need it.
    write_file(KEY, decode_pem(key_value, 'vaultwarden.tls-key'), 0o600,
               'root:root')
    cert_pub = capture(['openssl', 'x509', '-noout', '-pubkey', '-in', CERT])
    key_pub = capture(['openssl', 'pkey', '-pubout', '-in', KEY])
    if not cert_pub or not key_pub or cert_pub != key_pub:
        raise RuntimeError('vaultwarden.tls-key does not match'
                           ' vaultwarden.tls-cert')
    if os.path.exists(SELF_SIGNED):
        os.remove(SELF_SIGNED)
    log('installed the operator-supplied TLS certificate')
    return True


def certificate_names(fqdn, hostname, addresses):
    names = []
    for host in (fqdn, hostname, 'localhost'):
        if host and not is_address(host) and is_dns_name(host) \
                and host.lower() not in ('localhost.localdomain', '(none)'):
            entry = 'DNS:%s' % host.lower()
            if entry not in names:
                names.append(entry)
    for address in addresses + ['127.0.0.1']:
        entry = 'IP:%s' % address
        if entry not in names:
            names.append(entry)
    return names


def generate_certificate(fqdn, names):
    os.makedirs(TLS_DIR, mode=0o755, exist_ok=True)
    run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt',
         'ec_paramgen_curve:prime256v1', '-sha256', '-days', '825', '-nodes',
         '-keyout', KEY, '-out', CERT,
         '-subj', '/CN=%s' % (fqdn or 'vaultwarden'),
         '-addext', 'subjectAltName=%s' % ','.join(names),
         '-addext', 'extendedKeyUsage=serverAuth'],
        capture_output=True)
    run(['chown', 'root:root', KEY])
    os.chmod(KEY, 0o600)
    os.chmod(CERT, 0o644)
    write_file(SELF_SIGNED, '%s\n' % ','.join(names), 0o644)
    log('generated a self-signed certificate for %s' % ', '.join(names))


def apply_certificate(props, fqdn, addresses, first_boot):
    """Returns True when the served certificate changed."""
    if first_boot and install_operator_certificate(props):
        return True
    if os.path.exists(CERT) and not os.path.exists(SELF_SIGNED):
        return False  # operator-supplied; never touched again
    names = certificate_names(fqdn, socket.gethostname(), addresses)
    previous = ''
    if os.path.exists(SELF_SIGNED):
        with open(SELF_SIGNED) as handle:
            previous = handle.read().strip()
    if previous == ','.join(names) and os.path.exists(CERT):
        return False
    generate_certificate(fqdn, names)
    return True


#
# nginx and the firewall
#

def render_admin_snippet(admin_allow):
    lines = ['# Written by vaultwarden-firstboot.py from'
             ' vaultwarden.admin-allow.\n',
             '# Loopback is always allowed, so the admin page is reachable'
             ' over an SSH tunnel.\n',
             'allow 127.0.0.1;\n', 'allow ::1;\n']
    # Re-checked at the sink, so this stays safe however it is called.
    for entry in admin_allow:
        try:
            ipaddress.ip_network(entry, strict=False)
        except ValueError:
            continue
        lines.append('allow %s;\n' % entry)
    lines.append('deny all;\n')
    return ''.join(lines)


def write_nginx_snippets(fqdn, admin_allow, operator_certificate):
    name = fqdn if is_dns_name(fqdn) and not is_address(fqdn) else ''
    write_file(SNIPPET_SERVER_NAME,
               '# Written by vaultwarden-firstboot.py.\nserver_name %s_;\n'
               % ('%s ' % name if name else ''), 0o644)
    write_file(SNIPPET_ADMIN, render_admin_snippet(admin_allow), 0o644)
    hsts = '# Written by vaultwarden-firstboot.py.\n'
    if operator_certificate:
        hsts += ('add_header Strict-Transport-Security'
                 ' "max-age=31536000" always;\n')
    else:
        hsts += ('# Not sent: the certificate is self-signed, and HSTS would'
                 ' make the\n# browser warning impossible to click through.\n')
    write_file(SNIPPET_HSTS, hsts, 0o644)
    run(['nginx', '-t'], capture_output=True)


def firewall_rules(https_allow, ssh_allow, https_closed=False):
    """The ufw rules this appliance owns, as argument lists.

    HTTPS (and the plain-HTTP redirect) from the allowlist, or from anywhere
    when it is empty - or from nowhere (ufw's default deny) when the field
    was filled in with nothing valid, which is the one way to mistype an
    allowlist that cannot open the service to the world. SSH from the
    management allowlist when one is given; when it is empty, or invalid,
    the base image's own `allow ssh` rule is left in charge, because losing
    SSH over a typo would be worse than keeping the base posture.
    """
    rules = []
    for source in [] if https_closed else (https_allow or ['any']):
        rules.append(['allow', 'proto', 'tcp', 'from', source, 'to', 'any',
                      'port', '80,443', 'comment', 'vaultwarden-https'])
    for source in ssh_allow:
        rules.append(['allow', 'proto', 'tcp', 'from', source, 'to', 'any',
                      'port', '22', 'comment', 'vaultwarden-ssh'])
    return rules


def owned_rule_numbers(status_output):
    """Rule numbers carrying our comment, highest first for deletion."""
    numbers = []
    for line in status_output.splitlines():
        match = re.match(r'^\[\s*(\d+)\]\s.*#\s*vaultwarden-(https|ssh)\s*$',
                         line)
        if match:
            numbers.append(int(match.group(1)))
    return sorted(numbers, reverse=True)


def apply_firewall(https_allow, ssh_allow, https_closed=False):
    """Returns True when ufw was changed."""
    desired = {'rules': firewall_rules(https_allow, ssh_allow, https_closed),
               'base_ssh': not ssh_allow}
    previous = None
    if os.path.exists(FIREWALL_STATE):
        with open(FIREWALL_STATE) as handle:
            try:
                previous = json.load(handle)
            except ValueError:
                previous = None
    status = capture(['ufw', 'status', 'numbered'])
    if previous == desired and owned_rule_numbers(status):
        return False

    for number in owned_rule_numbers(status):
        run(['ufw', '--force', 'delete', str(number)], capture_output=True)
    for rule in desired['rules']:
        run(['ufw'] + rule, capture_output=True)
    if ssh_allow:
        # Added first and removed second, so there is never a moment with no
        # SSH rule at all. The console 'recovery' account is the way back if
        # the allowlist was wrong.
        run(['ufw', 'delete', 'allow', 'ssh'], check=False, capture_output=True)
        run(['ufw', 'delete', 'allow', '22/tcp'], check=False,
            capture_output=True)
    else:
        run(['ufw', 'allow', 'ssh'], capture_output=True)
    write_file(FIREWALL_STATE, json.dumps(desired, indent=2) + '\n', 0o644)
    log('firewall: HTTPS from %s; SSH from %s'
        % ('NOWHERE (vaultwarden.https-allow has no valid entry)'
           if https_closed else ', '.join(https_allow) or 'anywhere',
           ', '.join(ssh_allow) or 'anywhere (base image rule)'))
    return True


#
# Outbound proxy
#

# Stricter than the NetBox appliance's: no user:password@ at all. The value
# lands in /etc/environment (world-readable by convention), an apt
# configuration string, a systemd Environment= line and the container
# environment, so a proxy credential would be readable by every local account
# and visible in `docker inspect` - on a password manager that is not a
# trade-off worth offering. Use an unauthenticated proxy, allowlisted by
# source address. The character set also keeps `"`, `%` and `\` out of the
# three differently quoted sinks.
PROXY_RE = re.compile(
    r'^https?://'
    r'[A-Za-z0-9._-]+'
    r'(?::\d{1,5})?/?$')
NO_PROXY_RE = re.compile(r'^[A-Za-z0-9.*_-]+(?:/\d{1,3})?$')

ENVIRONMENT = '/etc/environment'
APT_PROXY = '/etc/apt/apt.conf.d/95vaultwarden-proxy'
# dockerd needs it to pull an upgrade; nothing else here makes outbound HTTP
# requests outside the container.
PROXY_DROPINS = ('/etc/systemd/system/docker.service.d/30-proxy.conf',)
MARK_BEGIN = '# --- vaultwarden-firstboot proxy (managed) ---'
MARK_END = '# --- end vaultwarden-firstboot proxy ---'


def scrub_proxy(url):
    return re.sub(r'//[^/@]+@', '//<redacted>@', url)


def proxy_values(props):
    """(proxy, no_proxy); proxy is '' when unset or invalid."""
    proxy = prop(props, 'vaultwarden.proxy')
    if proxy and not PROXY_RE.match(proxy):
        log('ignoring vaultwarden.proxy %r: expected http://host:port'
            % scrub_proxy(proxy))
        proxy = ''
    bypass = ['localhost', '127.0.0.1', '::1']
    for entry in split_list(prop(props, 'vaultwarden.no-proxy')):
        if NO_PROXY_RE.match(entry) and entry not in bypass:
            bypass.append(entry)
    return proxy, ','.join(bypass)


def proxy_environment(props):
    """For the container: icon downloads and push notifications."""
    proxy, no_proxy = proxy_values(props)
    if not proxy:
        return {}
    return {'HTTP_PROXY': proxy, 'HTTPS_PROXY': proxy, 'NO_PROXY': no_proxy}


def environment_without_block(text):
    out, skipping = [], False
    for line in text.splitlines():
        if line.strip() == MARK_BEGIN:
            skipping = True
            continue
        if line.strip() == MARK_END:
            skipping = False
            continue
        if not skipping:
            out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return '\n'.join(out)


def write_proxy(props):
    """Returns True when anything changed."""
    proxy, no_proxy = proxy_values(props)
    before = snapshot((ENVIRONMENT, APT_PROXY) + PROXY_DROPINS)

    existing = ''
    if os.path.exists(ENVIRONMENT):
        with open(ENVIRONMENT) as handle:
            existing = handle.read()
    body = environment_without_block(existing)
    if not proxy:
        write_file(ENVIRONMENT, body + '\n' if body else '', 0o644)
        for path in (APT_PROXY,) + PROXY_DROPINS:
            if os.path.exists(path):
                os.remove(path)
    else:
        lines = [body] if body else []
        lines.append(MARK_BEGIN)
        for name in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'):
            lines.append('%s=%s' % (name, proxy))
        for name in ('no_proxy', 'NO_PROXY'):
            lines.append('%s=%s' % (name, no_proxy))
        lines.append(MARK_END)
        write_file(ENVIRONMENT, '\n'.join(lines) + '\n', 0o644)
        write_file(APT_PROXY,
                   '// Written by vaultwarden-firstboot.py from the deploy'
                   ' form.\nAcquire::http::Proxy "%s";\n'
                   'Acquire::https::Proxy "%s";\n' % (proxy, proxy), 0o600)
        for path in PROXY_DROPINS:
            write_file(path,
                       '# Written by vaultwarden-firstboot.py.\n[Service]\n'
                       'Environment=HTTP_PROXY=%s\nEnvironment=HTTPS_PROXY=%s\n'
                       'Environment=NO_PROXY=%s\n' % (proxy, proxy, no_proxy),
                       0o600)
    changed = snapshot((ENVIRONMENT, APT_PROXY) + PROXY_DROPINS) != before
    if changed:
        run(['systemctl', 'daemon-reload'], check=False)
        log('outbound proxy %s' % ('set to %s (bypass: %s)'
                                   % (scrub_proxy(proxy), no_proxy)
                                   if proxy else 'cleared'))
        # daemon-reload only re-reads the unit; a running dockerd keeps the
        # environment it started with, and image pulls would keep going the
        # old way. At boot the units are ordered Before=docker.service, so
        # dockerd starts with the drop-in in place; outside boot the daemon
        # is restarted here (which restarts vaultwarden.service with it,
        # PartOf). Inside our own unit the restart is queued rather than
        # waited on, for the reason restart_services() gives.
        if not system_is_booting():
            command = ['systemctl', 'try-restart', 'docker.service']
            if in_appliance_unit():
                command.insert(1, '--no-block')
            run(command, check=False)
            log('docker restarted to pick up the proxy change')
    return changed


#
# Files
#

def write_file(path, content, mode, owner=None):
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(descriptor, 'wb' if isinstance(content, bytes) else 'w') \
            as handle:
        handle.write(content)
    os.chmod(path, mode)
    if owner:
        run(['chown', owner, path])


def snapshot(paths):
    contents = []
    for path in paths:
        try:
            with open(path, 'rb') as handle:
                contents.append(handle.read())
        except OSError:
            contents.append(None)
    return contents


def write_if_changed(path, content, mode, owner=None):
    if snapshot([path]) == [content.encode()]:
        return False
    write_file(path, content, mode, owner)
    return True


#
# Credentials
#

def write_credentials(state, token):
    lines = [
        'Vaultwarden appliance credentials',
        '=================================',
        '',
        'URL:          %s' % state['url'],
        'Admin page:   %sadmin  (reachable from: %s)'
        % (state['url'], state['admin_access']),
        'Admin token:  %s' % token,
        '',
        'This is the admin *token*, not a user account. Only its argon2id hash',
        'is stored on the appliance; this file is the one plaintext copy.',
        'Keep it in your break-glass store, then remove this file:',
        '',
        '    vaultwarden-credentials --clear',
        '',
        'Generated at %s.' % state['bootstrapped_at'],
        '',
    ]
    write_file(CREDENTIALS, '\n'.join(lines), 0o600)
    # The local console only: the hardened base uses /etc/issue.net as the
    # pre-authentication SSH banner, which must never carry this.
    write_file(ISSUE,
               '\nVaultwarden appliance -- %s\n'
               '  admin token: %s\n'
               '  Remove this banner once stored: vaultwarden-credentials'
               ' --clear\n\n' % (state['url'], token), 0o600)


#
# Services
#

def system_is_booting():
    result = subprocess.run(['systemctl', 'is-system-running'],
                            text=True, capture_output=True)
    return result.stdout.strip() in ('initializing', 'starting')


def in_appliance_unit():
    """Running as one of our own units (not a shell started from one)?"""
    try:
        with open(CGROUP) as handle:
            cgroup = handle.read()
    except OSError:
        return False
    return ('vaultwarden-reconcile.service' in cgroup
            or 'vaultwarden-bootstrap.service' in cgroup)


def restart_services():
    """Pick up the new configuration - but never during boot.

    The same trap as on the NetBox appliance: vaultwarden.service and
    nginx.service are ordered after this unit, so at boot they already have
    start jobs queued behind it, and a try-restart for a unit without
    ExecReload replaces that queued start and then does nothing. At boot the
    ordering starts them with the new files; only a manual re-run restarts.
    Inside our own unit outside boot, waiting on jobs ordered after us
    deadlocks, so the restarts are queued instead.
    """
    if system_is_booting():
        log('boot in progress; vaultwarden and nginx start from their own'
            ' ordering')
        return
    command = ['systemctl', 'try-reload-or-restart', 'vaultwarden.service',
               'nginx.service']
    if in_appliance_unit():
        command.insert(1, '--no-block')
    run(command, check=False)


#
# Bootstrap and reconcile
#

def image_reference():
    try:
        with open(COMPOSE_ENV) as handle:
            for line in handle:
                if line.startswith('VAULTWARDEN_IMAGE='):
                    return line.split('=', 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return 'unknown'


def apply_configuration(props, first_boot):
    """Everything both modes share. Returns (state, generated_token, changed)."""
    fqdn, addresses = resolve_identity(props)
    log('identity: %s' % (fqdn or '(none)'))
    # An invalid-only admin allowlist already fails closed: the snippet then
    # allows loopback and denies the rest.
    admin_allow, _ = allowlist(props, 'vaultwarden.admin-allow')
    https_allow, https_closed = allowlist(props, 'vaultwarden.https-allow')
    ssh_allow, ssh_invalid = allowlist(props, 'vaultwarden.ssh-allow')

    changed = False
    token = apply_secrets(props, first_boot)
    changed |= bool(token)

    settings = build_settings(props, fqdn, have_secret)
    changed |= write_if_changed(ENV_FILE, render_env(settings), 0o600,
                                'root:root')

    changed |= apply_certificate(props, fqdn, addresses, first_boot)
    operator_certificate = not os.path.exists(SELF_SIGNED)
    before = snapshot([SNIPPET_SERVER_NAME, SNIPPET_ADMIN, SNIPPET_HSTS])
    write_nginx_snippets(fqdn, admin_allow, operator_certificate)
    changed |= snapshot([SNIPPET_SERVER_NAME, SNIPPET_ADMIN,
                         SNIPPET_HSTS]) != before

    changed |= apply_firewall(https_allow, ssh_allow, https_closed)
    changed |= write_proxy(props)

    state = {}
    if os.path.exists(STATE):
        with open(STATE) as handle:
            try:
                state = json.load(handle)
            except ValueError:
                state = {}
    state.update({
        'fqdn': fqdn,
        'url': settings['DOMAIN'] + '/',
        'image': image_reference(),
        'self_signed_certificate': not operator_certificate,
        'smtp': 'SMTP_HOST' in settings,
        'sso': settings.get('SSO_ENABLED') == 'true',
        'org_creation_users': settings['ORG_CREATION_USERS'],
        'admin_access': ', '.join(['loopback'] + admin_allow),
        # vaultwarden-status keys off the CLOSED prefix.
        'https_allow': ('CLOSED - vaultwarden.https-allow has no valid entry'
                        if https_closed else ', '.join(https_allow)
                        or 'anywhere'),
        'ssh_allow': ('anywhere (base rule; vaultwarden.ssh-allow has no'
                      ' valid entry)' if ssh_invalid
                      else ', '.join(ssh_allow) or 'anywhere'),
    })
    return state, token, changed


def bootstrap(props):
    volume, adopted = ensure_volume()
    # The signing key is the data disk's own evidence that an instance lived
    # here, independent of anything on the root disk.
    key_present = os.path.exists(os.path.join(DATA_DIR, 'rsa_key.pem'))
    has_schema = ensure_database()
    if adopted and key_present and not has_schema:
        raise RuntimeError(
            'the data disk %s carries a Vaultwarden signing key but its'
            ' database has no schema; starting now would create an empty'
            ' instance over the top of a lost one. Restore it:'
            ' vaultwarden-restore <backup>' % volume)
    if adopted and (has_schema or key_present):
        # An existing data disk with an existing instance: protect it from
        # the very first start, rather than only after Vaultwarden has run
        # once on this deployment.
        write_file(INITIALIZED, 'adopted %s\n' % volume, 0o644)

    state, token, _ = apply_configuration(props, first_boot=True)
    state['volume_id'] = volume
    state['bootstrapped_at'] = datetime.datetime.now(
        datetime.timezone.utc).replace(microsecond=0).isoformat()
    write_file(STATE, json.dumps(state, indent=2, sort_keys=True) + '\n',
               0o644)
    if token:
        write_credentials(state, token)

    if os.path.exists(FAILURE):
        os.remove(FAILURE)
    write_file(MARKER, '%s\n' % state['bootstrapped_at'], 0o644)
    restart_services()
    log('bootstrap complete: %s' % state['url'])


def reconcile(props):
    state, _, changed = apply_configuration(props, first_boot=False)
    write_file(STATE, json.dumps(state, indent=2, sort_keys=True) + '\n',
               0o644)
    if changed:
        restart_services()
        log('reconciled')
    else:
        log('nothing to reconcile')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reconcile', action='store_true',
                        help='re-apply configuration only; never generate'
                             ' secrets or touch data')
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
            ' VAULTWARDEN APPLIANCE %s FAILED\n'
            ' %s\n'
            ' Details: %s\n'
            ' Retry with: systemctl start vaultwarden-%s\n'
            '========================================================\n'
            % ('RECONCILE' if arguments.reconcile else 'BOOTSTRAP', exc,
               FAILURE, 'reconcile' if arguments.reconcile else 'bootstrap'))
        sys.stderr.write(detail)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
