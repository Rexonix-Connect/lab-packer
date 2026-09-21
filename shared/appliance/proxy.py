"""Point an appliance's own outbound traffic at a customer proxy, or clear it.

Shared by every appliance in this repository. The rules here were worked out
for the NetBox appliance and are not obvious enough to be worth writing twice:

  - The value is validated STRICTLY rather than escaped. It lands in an apt
    configuration string, a systemd `Environment=` line and /etc/environment,
    none of which are quoted the same way, so anything that could terminate a
    string or start a new directive is refused instead of escaped three
    different ways.

  - The bypass list is filtered to plain hosts, domains and CIDRs on the same
    reasoning, and loopback is always bypassed.

  - A proxy URL may carry user:password@. That never reaches a log line: the
    journal is what a support bundle ships off the machine, and the bundle
    promises to contain no secrets.

  - Everything is applied on EVERY run, not only the first. A customer's proxy
    can be introduced or changed after deployment, and clearing the field has
    to clear the proxy everywhere rather than leave a stale one that silently
    breaks patching. That is why the /etc/environment edit is a marked block
    this module owns and rewrites, rather than lines appended to the file.

The caller supplies a Spec describing what is appliance-specific: which deploy
form properties to read, where its apt configuration goes, and which systemd
units need a drop-in because a unit does not inherit /etc/environment.

apply() returns a Result whose `changed` flag says whether anything on disk
actually moved. Callers use it to decide what to restart: an appliance whose
container runtime reads the proxy at daemon start needs a restart when it
changes, and must not bounce itself on every boot when it has not.
"""
import os
import re
import subprocess

__all__ = ['Spec', 'Result', 'apply', 'scrub', 'parse_bypass', 'PROXY_RE']

# Deliberately strict; see the module docstring.
PROXY_RE = re.compile(
    r'^https?://'                          # scheme, so apt and pip agree
    r'(?:[^\s:@/]+(?::[^\s:@/]*)?@)?'      # optional user:password
    r'[A-Za-z0-9._-]+'                     # host
    r'(?::\d{1,5})?/?$')                   # optional port
BYPASS_RE = re.compile(r'^[A-Za-z0-9.*_-]+(?:/\d{1,3})?$')

ENVIRONMENT = '/etc/environment'
MARK_BEGIN = '# --- lab-appliance proxy (managed) ---'
MARK_END = '# --- end lab-appliance proxy ---'

# Historical markers this module also strips, so an appliance built before the
# logic was shared does not end up with two managed blocks in /etc/environment
# after an in-place upgrade. Removing a marker from this tuple orphans a block
# on every appliance already carrying it.
LEGACY_MARKERS = (
    ('# --- netbox-firstboot proxy (managed) ---',
     '# --- end netbox-firstboot proxy ---'),
)

# Always bypassed, whatever the form says: an appliance must never send its own
# loopback traffic through a customer proxy.
ALWAYS_BYPASS = ('localhost', '127.0.0.1', '::1')


class Spec:
    """What differs between appliances.

    proxy_property / bypass_property
        Deploy-form ids, for example 'netbox.proxy' and 'netbox.no-proxy'.
    apt_config
        Absolute path for the apt proxy configuration. apt is configured
        through apt.conf rather than the environment, and apt.conf is what
        unattended-upgrades honours, so this is not optional on any appliance
        that patches itself.
    dropins
        Absolute paths of systemd drop-ins to write. A unit does not inherit
        /etc/environment, so anything that reaches out from a service needs
        one. Empty is valid.
    attribution
        The 'Written by X' line put at the top of each generated file.
    """

    def __init__(self, proxy_property, bypass_property, apt_config,
                 dropins=(), attribution='the appliance bootstrap'):
        self.proxy_property = proxy_property
        self.bypass_property = bypass_property
        self.apt_config = apt_config
        self.dropins = tuple(dropins)
        self.attribution = attribution


class Result:
    """What apply() did.

    proxy
        The accepted proxy URL, or '' when none is configured (including when
        the form's value was refused).
    no_proxy
        The comma-separated bypass list that was written.
    changed
        True when any managed file was created, rewritten with different
        content, or removed.
    """

    def __init__(self, proxy, no_proxy, changed):
        self.proxy = proxy
        self.no_proxy = no_proxy
        self.changed = changed

    def __repr__(self):
        return ('Result(proxy=%r, no_proxy=%r, changed=%r)'
                % (scrub(self.proxy), self.no_proxy, self.changed))


def scrub(url):
    """Redact any user:password@ before the value reaches a log line."""
    return re.sub(r'//[^/@]+@', '//<redacted>@', url or '')


def parse_bypass(value, log):
    """Split the bypass list, dropping anything that is not a plain host."""
    entries = []
    for raw in re.split(r'[,\s]+', value or ''):
        entry = raw.strip()
        if not entry:
            continue
        if BYPASS_RE.match(entry):
            if entry not in entries:
                entries.append(entry)
        else:
            log('ignoring proxy bypass entry %r: not a host, domain or CIDR'
                % entry)
    return entries


def _strip_managed_block(text):
    """The file with any block this module owns - current or historical - gone."""
    markers = ((MARK_BEGIN, MARK_END),) + LEGACY_MARKERS
    out, skipping = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if not skipping and any(stripped == begin for begin, _ in markers):
            skipping = True
            continue
        if skipping and any(stripped == end for _, end in markers):
            skipping = False
            continue
        if not skipping:
            out.append(line)
    while out and not out[-1].strip():
        out.pop()
    return '\n'.join(out)


def _write(path, content, mode):
    """Write atomically with an explicit mode, and say whether it changed.

    Atomic because /etc/environment is read by every login: a partially
    written one is a broken machine, and the window is otherwise real.

    The mode is set on the temporary file BEFORE the rename, so the content
    is never briefly readable at the default umask - which matters for the apt
    configuration and the drop-ins, both of which may carry a proxy password.
    """
    existing = None
    if os.path.exists(path):
        with open(path) as handle:
            existing = handle.read()
    if existing == content and _mode_of(path) == mode:
        return False

    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, mode=0o755, exist_ok=True)
    temporary = '%s.tmp' % path
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(descriptor, 'w') as handle:
            handle.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except Exception:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise
    return True


def _mode_of(path):
    try:
        return os.stat(path).st_mode & 0o777
    except OSError:
        return None


def _remove(path):
    if os.path.exists(path):
        os.remove(path)
        return True
    return False


def apply(props, spec, log, run=None, root=''):
    """Apply the deploy form's proxy settings. Returns a Result.

    props   deploy-form properties, as a dict of id -> value
    spec    a Spec describing this appliance
    log     one-argument logger; the caller's, so the prefix stays right
    run     subprocess.run stand-in, for the systemctl daemon-reload
    root    path prefix, for testing against a temporary tree
    """
    if run is None:
        run = subprocess.run

    def path(absolute):
        return os.path.join(root, absolute.lstrip('/')) if root else absolute

    proxy = (props.get(spec.proxy_property) or '').strip()
    if proxy and not PROXY_RE.match(proxy):
        # Log the scrubbed form: a value rejected for being malformed may
        # still contain a password, and a rejection is not a reason to print
        # one into the journal.
        log('ignoring %s %r: expected http://host[:port]'
            % (spec.proxy_property, scrub(proxy)))
        proxy = ''

    bypass = list(ALWAYS_BYPASS) + parse_bypass(
        props.get(spec.bypass_property), log)
    no_proxy = ','.join(bypass)

    environment = path(ENVIRONMENT)
    existing = ''
    if os.path.exists(environment):
        with open(environment) as handle:
            existing = handle.read()
    body = _strip_managed_block(existing)

    changed = False

    if not proxy:
        changed |= _write(environment, body + '\n' if body else '', 0o644)
        for target in (spec.apt_config,) + spec.dropins:
            changed |= _remove(path(target))
        if changed:
            run(['systemctl', 'daemon-reload'], check=False)
        log('no proxy configured; outbound traffic goes direct')
        return Result('', no_proxy, changed)

    lines = [body] if body else []
    lines.append(MARK_BEGIN)
    for name in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'):
        lines.append('%s=%s' % (name, proxy))
    for name in ('no_proxy', 'NO_PROXY'):
        lines.append('%s=%s' % (name, no_proxy))
    lines.append(MARK_END)
    changed |= _write(environment, '\n'.join(lines) + '\n', 0o644)

    # 0600, not 0644: apt reads this as root and the URL may carry
    # credentials. /etc/environment stays world-readable by convention and
    # necessity - prefer an unauthenticated proxy where possible.
    changed |= _write(path(spec.apt_config),
                      '// Written by %s from the deploy form.\n'
                      'Acquire::http::Proxy "%s";\n'
                      'Acquire::https::Proxy "%s";\n'
                      % (spec.attribution, proxy, proxy), 0o600)

    for target in spec.dropins:
        changed |= _write(path(target),
                          '# Written by %s from the deploy form.\n'
                          '[Service]\n'
                          'Environment=http_proxy=%s\n'
                          'Environment=https_proxy=%s\n'
                          'Environment=no_proxy=%s\n'
                          % (spec.attribution, proxy, proxy, no_proxy), 0o600)

    if changed:
        run(['systemctl', 'daemon-reload'], check=False)
    log('outbound proxy set to %s (bypass: %s)' % (scrub(proxy), no_proxy))
    return Result(proxy, no_proxy, changed)
