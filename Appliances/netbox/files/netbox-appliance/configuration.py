"""NetBox configuration for the lab-packer NetBox appliance image.

This file is static: it is part of the image and is identical in every
deployment. Everything deployment specific - host names, secrets, the database
and cache to talk to, the time zone, whether metrics are exposed - lives in
/etc/netbox/appliance.json, which netbox-firstboot.py writes on the first boot
of a deployment from the vSphere deploy form.

Splitting the two apart buys three things: the exported template ships without
the JSON and therefore without a single secret; an upgrade never has to merge
an operator-edited settings file; and re-running the bootstrap is a matter of
rewriting one JSON document.

To add settings NetBox supports but the appliance does not surface, append them
at the bottom of this file - it survives netbox-upgrade untouched.
"""
import json
import os

APPLIANCE_CONFIG = os.environ.get(
    'NETBOX_APPLIANCE_CONFIG', '/etc/netbox/appliance.json')

try:
    with open(APPLIANCE_CONFIG) as _fh:
        _appliance = json.load(_fh)
except FileNotFoundError:
    raise SystemExit(
        "%s does not exist, so this NetBox appliance has not been "
        "bootstrapped yet. Check 'systemctl status netbox-bootstrap' and "
        "'journalctl -u netbox-bootstrap -b'." % APPLIANCE_CONFIG
    )

#
# Required settings
#

ALLOWED_HOSTS = _appliance['allowed_hosts']

DATABASES = {
    'default': _appliance['database'],
}

REDIS = _appliance['redis']

SECRET_KEY = _appliance['secret_key']

# JSON object keys are strings; NetBox expects the pepper ids to be integers.
API_TOKEN_PEPPERS = {
    int(key): value
    for key, value in _appliance.get('api_token_peppers', {}).items()
}

#
# Appliance settings
#

DEBUG = False

TIME_ZONE = _appliance.get('time_zone', 'UTC')

METRICS_ENABLED = _appliance.get('metrics_enabled', False)

PLUGINS = _appliance.get('plugins', [])

PLUGINS_CONFIG = _appliance.get('plugins_config', {})

# nginx terminates TLS and the appliance redirects plain HTTP to it, so the
# session and CSRF cookies are never sent in the clear.
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_SECURE = True

# NetBox already sets USE_X_FORWARDED_HOST and trusts X-Forwarded-Proto, so
# Django sees the client-facing host. Naming the same hosts here as trusted
# CSRF origins avoids "CSRF verification failed" on the login form when the
# appliance is reached by a name rather than by address.
CSRF_TRUSTED_ORIGINS = [
    'https://%s' % host for host in ALLOWED_HOSTS if host != '*'
]

# Logged to a file rather than only to the journal, because the appliance's
# fail2ban and logrotate configuration expect it there.
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'appliance': {
            'format': '%(asctime)s %(levelname)s %(name)s %(message)s',
        },
    },
    'handlers': {
        'file': {
            'class': 'logging.FileHandler',
            'filename': '/var/log/netbox/netbox.log',
            'formatter': 'appliance',
            # Opened on first use so a management command run by another
            # account cannot fail merely because it cannot open the log.
            'delay': True,
        },
    },
    'loggers': {
        'netbox': {'handlers': ['file'], 'level': 'INFO'},
        'django': {'handlers': ['file'], 'level': 'WARNING'},
    },
}
