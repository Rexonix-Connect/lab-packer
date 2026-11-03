#!/bin/bash
# The Vaultwarden Compose project and its systemd unit.
#
# Nothing here generates a secret or creates data: the database, the data
# directory contents, the admin token and the RSA signing key are all created
# per deployment by vaultwarden-firstboot.py and by Vaultwarden itself.
set -euo pipefail

: "${VAULTWARDEN_IMAGE:?}"
DATA_ROOT=/srv/vaultwarden
CONFIG_DIR=/etc/vaultwarden
findmnt --noheadings --mountpoint "${DATA_ROOT}" >/dev/null

uid="$(id -u vaultwarden)"
gid="$(id -g vaultwarden)"

echo '> Installing the Compose project ...'
install -d -m 0751 -o root -g root "${CONFIG_DIR}"
install -d -m 0750 -o root -g vaultwarden "${CONFIG_DIR}/secrets"
install -m 0644 -o root -g root "${PAYLOAD_DIR}/compose/compose.yaml" "${CONFIG_DIR}/compose.yaml"
# Interpolation values for compose.yaml, not container settings. The image is
# rewritten by vaultwarden-upgrade; the uid is resolved here, on the image that
# owns the account.
cat >"${CONFIG_DIR}/.env" <<ENV
# Written at build time; vaultwarden-upgrade rewrites VAULTWARDEN_IMAGE.
VAULTWARDEN_IMAGE=${VAULTWARDEN_IMAGE}
VAULTWARDEN_UID=${uid}
VAULTWARDEN_GID=${gid}
ENV
chmod 0644 "${CONFIG_DIR}/.env"

echo '> Preparing the data directories ...'
install -d -m 0700 -o vaultwarden -g vaultwarden "${DATA_ROOT}/data"
install -d -m 0700 -o root -g root "${DATA_ROOT}/backups"
install -d -m 0755 -o root -g root /var/lib/vaultwarden-appliance

echo '> Installing the units ...'
for unit in vaultwarden.service vaultwarden-datadisk.service; do
	install -m 0644 -o root -g root "${PAYLOAD_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
install -d -m 0755 /etc/systemd/system/postgresql@.service.d
install -m 0644 -o root -g root "${PAYLOAD_DIR}/systemd/postgresql-datadisk.conf" \
	/etc/systemd/system/postgresql@.service.d/10-vaultwarden-datadisk.conf

echo '> Validating the Compose project ...'
# A placeholder settings file so `config` can resolve env_file; the bootstrap
# writes the real one, verify.sh a build-only one.
install -m 0600 /dev/null "${CONFIG_DIR}/vaultwarden.env"
docker compose --project-directory "${CONFIG_DIR}" config --quiet
rm -f "${CONFIG_DIR}/vaultwarden.env"

systemctl daemon-reload
systemctl enable vaultwarden.service vaultwarden-datadisk.service
echo '> Vaultwarden installed.'
