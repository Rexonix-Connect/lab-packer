#!/bin/bash
# Install NetBox itself at the pinned release, with a local PostgreSQL database
# that is already migrated by the time the template is exported.
#
# Local database authentication is peer over the Unix socket, so the appliance
# never has a database password to generate, bake, rotate or leak. That is what
# makes it safe to ship the migrated schema in the template: the only secrets
# NetBox needs (SECRET_KEY, the API token pepper) live in
# /etc/netbox/appliance.json, which finalize.sh deletes and the first-boot
# bootstrap writes afresh per deployment.
set -euo pipefail

# NetBox lives on the data disk and is reached through /opt/netbox, the path
# upstream's systemd units, gunicorn configuration and the nginx static alias
# all hardcode. Everything in this image keeps referring to /opt/netbox; only
# the two lines below know where it physically is.
DATA_ROOT=/srv/netbox
NETBOX_ROOT=/opt/netbox
BACKUP_DIR="${DATA_ROOT}/backups"
CONFIG_DIR=/etc/netbox

# install-datadisk.sh runs first and must have mounted it; without that this
# would install NetBox onto the root disk the split exists to protect.
findmnt --noheadings --mountpoint "${DATA_ROOT}" >/dev/null

echo "> Creating the netbox service account and directories ..."
if ! id netbox >/dev/null 2>&1; then
	adduser --system --group netbox
fi
install -d -m 0750 -o root -g netbox "${CONFIG_DIR}"
install -d -m 0750 -o netbox -g adm /var/log/netbox
install -d -m 0755 -o root -g root /var/lib/netbox-appliance
# Backups belong with the data they protect, and they are the other thing that
# grows without bound. /var/backups/netbox stays as a symlink so the documented
# path keeps working.
install -d -m 0700 -o root -g root "${BACKUP_DIR}"
if [ ! -L /var/backups/netbox ]; then
	rm -rf /var/backups/netbox
	ln -s "${BACKUP_DIR}" /var/backups/netbox
fi

echo "> Pointing ${NETBOX_ROOT} at ${DATA_ROOT} ..."
if [ ! -L "${NETBOX_ROOT}" ]; then
	if [ -e "${NETBOX_ROOT}" ]; then
		echo "> ${NETBOX_ROOT} exists and is not a symlink; refusing to replace it"
		exit 1
	fi
	ln -s "${DATA_ROOT}" "${NETBOX_ROOT}"
fi
if [ "$(readlink -f "${NETBOX_ROOT}")" != "${DATA_ROOT}" ]; then
	echo "> ${NETBOX_ROOT} does not resolve to ${DATA_ROOT}"
	exit 1
fi

echo "> Cloning NetBox ${NETBOX_VERSION} ..."
# init+fetch rather than `git clone`, because the mount point is not empty
# (ext4 puts lost+found there) and clone refuses a non-empty target. Full
# history, not --depth 1, so netbox-upgrade can check out any other release
# later without re-fetching everything first.
if [ ! -d "${DATA_ROOT}/.git" ]; then
	git init --quiet --initial-branch=main "${DATA_ROOT}"
	git -C "${DATA_ROOT}" remote add origin "${NETBOX_REPO_URL}"
fi
git -C "${DATA_ROOT}" fetch --quiet --tags origin
git -C "${NETBOX_ROOT}" checkout --quiet "tags/${NETBOX_VERSION}"
checked_out="$(git -C "${NETBOX_ROOT}" describe --tags --exact-match)"
if [ "${checked_out}" != "${NETBOX_VERSION}" ]; then
	echo "> checked out ${checked_out}, expected ${NETBOX_VERSION}"
	exit 1
fi
echo "> NetBox ${checked_out} checked out."

install -d -m 0755 -o netbox -g netbox \
	"${NETBOX_ROOT}/netbox/media" \
	"${NETBOX_ROOT}/netbox/reports" \
	"${NETBOX_ROOT}/netbox/scripts"
chown -R netbox:netbox \
	"${NETBOX_ROOT}/netbox/media" \
	"${NETBOX_ROOT}/netbox/reports" \
	"${NETBOX_ROOT}/netbox/scripts"

if [ ! -f "${NETBOX_ROOT}/local_requirements.txt" ]; then
	cat >"${NETBOX_ROOT}/local_requirements.txt" <<'EOF'
# Extra Python packages for this appliance - NetBox plugins, authentication
# backends, storage backends. Pin every entry, then apply them with:
#
#     netbox-upgrade --reinstall
#
# Plugins also have to be listed in PLUGINS in /etc/netbox/appliance.json.
EOF
fi

echo "> Installing the appliance configuration loader ..."
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/configuration.py" "${NETBOX_ROOT}/netbox/netbox/configuration.py"

echo "> Preparing the local PostgreSQL database ..."
pg_version="$(pg_lsclusters -h | awk 'NR==1{print $1}')"
pg_cluster="$(pg_lsclusters -h | awk 'NR==1{print $2}')"
pg_conf_dir="/etc/postgresql/${pg_version}/${pg_cluster}"
pg_data="${DATA_ROOT}/postgresql/${pg_version}/${pg_cluster}"

# The database is the fastest-growing thing on the appliance, so its data
# directory belongs on the data disk. The configuration stays in
# /etc/postgresql, so the peer-authentication edits below are unaffected.
if [ "$(pg_lsclusters -h | awk 'NR==1{print $6}')" != "${pg_data}" ]; then
	echo "> Recreating cluster ${pg_version}/${pg_cluster} at ${pg_data} ..."
	install -d -m 0755 -o postgres -g postgres "${DATA_ROOT}/postgresql"
	pg_dropcluster --stop "${pg_version}" "${pg_cluster}"
	# Encoding and locale are pinned rather than inherited from the image:
	# NetBox's documentation warns explicitly that a SQL_ASCII cluster leads
	# to "unpredictable and unrecoverable errors", and the base image's locale
	# is not guaranteed to be a UTF-8 one.
	pg_createcluster --locale=C.UTF-8 --encoding=UTF8 \
		--datadir="${pg_data}" "${pg_version}" "${pg_cluster}" --start
fi
systemctl start postgresql
[ "$(pg_lsclusters -h | awk 'NR==1{print $6}')" = "${pg_data}" ]

# Peer authentication matches the connecting OS user against the database role.
# NetBox runs as netbox and matches directly; root has to be mapped, because
# upgrade.sh and the first-boot bootstrap run migrations as root. This grants
# root nothing it could not already get by becoming the netbox user.
if ! grep -q 'netbox_admins' "${pg_conf_dir}/pg_ident.conf"; then
	cat >>"${pg_conf_dir}/pg_ident.conf" <<'EOF'

# lab-packer NetBox appliance: let root run migrations as the netbox role.
netbox_admins   root            netbox
netbox_admins   netbox          netbox
EOF
fi
if ! grep -q 'map=netbox_admins' "${pg_conf_dir}/pg_hba.conf"; then
	# First match wins, so this specific rule has to precede the stock
	# "local all all peer" line rather than be appended after it.
	tmp_hba="$(mktemp)"
	cat >"${tmp_hba}" <<'EOF'
# lab-packer NetBox appliance: socket access to the netbox database for the
# netbox service account and for root-run migrations (see pg_ident.conf).
local   netbox          netbox                                  peer map=netbox_admins
EOF
	cat "${pg_conf_dir}/pg_hba.conf" >>"${tmp_hba}"
	install -m 0640 -o postgres -g postgres "${tmp_hba}" "${pg_conf_dir}/pg_hba.conf"
	rm -f "${tmp_hba}"
fi
systemctl reload postgresql

runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'netbox') THEN
        CREATE ROLE netbox LOGIN;
    END IF;
END
$$;
SQL
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='netbox'" | grep -qx 1; then
	runuser -u postgres -- createdb --encoding=UTF8 --owner=netbox netbox
fi
# Required on PostgreSQL 15+, where the public schema is no longer writable by
# every role.
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d netbox \
	-c 'GRANT CREATE ON SCHEMA public TO netbox'
runuser -u netbox -- psql -d netbox -tAc 'SELECT 1' | grep -qx 1
echo "> PostgreSQL ${pg_version}/${pg_cluster} ready with peer authentication."

echo '> Writing the build-time appliance configuration ...'
# Throwaway values: this file only has to satisfy NetBox's settings validation
# so upgrade.sh can migrate and collect static files. finalize.sh deletes it,
# and netbox-firstboot.py writes the real one on the first boot of a
# deployment.
python3 - "${CONFIG_DIR}/appliance.json" <<'PY'
import json
import secrets
import sys

with open(sys.argv[1], "w") as fh:
    json.dump({
        "allowed_hosts": ["*"],
        "database": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": "netbox",
            "USER": "netbox",
            "PASSWORD": "",
            "HOST": "",
            "PORT": "",
            "CONN_MAX_AGE": 300,
        },
        "redis": {
            "tasks": {"HOST": "localhost", "PORT": 6379, "USERNAME": "",
                      "PASSWORD": "", "DATABASE": 0, "SSL": False},
            "caching": {"HOST": "localhost", "PORT": 6379, "USERNAME": "",
                        "PASSWORD": "", "DATABASE": 1, "SSL": False},
        },
        "secret_key": secrets.token_urlsafe(64)[:60],
        "api_token_peppers": {"1": secrets.token_urlsafe(64)[:60]},
        "time_zone": "UTC",
        "metrics_enabled": False,
        "build_time": True,
    }, fh, indent=2)
PY
chown root:netbox "${CONFIG_DIR}/appliance.json"
chmod 0640 "${CONFIG_DIR}/appliance.json"

echo '> Building the virtual environment and migrating the database ...'
# upgrade.sh creates the venv, installs the pinned requirements and
# local_requirements.txt, migrates, traces cable paths, builds the bundled
# documentation, collects static files, prunes stale content types, rebuilds
# the search index and clears sessions.
"${NETBOX_ROOT}/upgrade.sh"

echo '> Installing systemd units ...'
install -m 0644 -o root -g root \
	"${NETBOX_ROOT}/contrib/netbox.service" /etc/systemd/system/netbox.service
install -m 0644 -o root -g root \
	"${NETBOX_ROOT}/contrib/netbox-rq.service" /etc/systemd/system/netbox-rq.service
install -m 0644 -o root -g root "${NETBOX_ROOT}/contrib/gunicorn.py" "${NETBOX_ROOT}/gunicorn.py"
# gunicorn 25 added a control interface backed by a Unix socket, created by
# default at /run/gunicorn.ctl. netbox.service runs as the unprivileged netbox
# account, which cannot write there, so every start logs
#
#     [ERROR] Control server error: [Errno 13] Permission denied
#
# It is not fatal - the workers boot and serve regardless - but an ERROR on
# every start of a production appliance is exactly the kind of noise that
# teaches an operator to ignore the log. Nothing here uses gunicornc, so the
# socket is turned off rather than relocated. This file is untracked by git,
# so netbox-upgrade leaves it alone.
cat >>"${NETBOX_ROOT}/gunicorn.py" <<'EOF'

# --- lab-packer appliance additions ---
control_socket_disable = True
EOF

for unit in netbox netbox-rq; do
	install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
	install -m 0644 -o root -g root \
		"${PAYLOAD_DIR}/systemd/netbox-hardening.conf" \
		"/etc/systemd/system/${unit}.service.d/10-hardening.conf"
done

systemctl daemon-reload
systemctl enable netbox.service netbox-rq.service
echo '> NetBox installed.'
