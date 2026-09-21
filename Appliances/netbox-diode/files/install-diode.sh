#!/bin/bash
# Install the Diode server compose project and bake its container images into
# the template.
#
# The images are pulled here, at build time, onto the data disk - so they ship
# inside the exported template and a deployed appliance never needs a registry.
# That is the same bet the NetBox appliance makes by shipping its migrated
# database: an air-gapped site cannot pull, and a template that behaves
# differently depending on when it is deployed is not a template.
#
# What ships: the compose file, the ingress configuration, the environment
# TEMPLATE and the container images. What does not ship: the rendered .env, the
# OAuth2 client secrets and the named volumes - all generated per deployment by
# diode-firstboot.py, and all removed again by finalize.sh.
set -euo pipefail

CONFIG_DIR=/etc/diode
PROJECT_DIR="${CONFIG_DIR}/compose"
DATA_ROOT=/srv/diode
BACKUP_DIR="${DATA_ROOT}/backups"

findmnt --noheadings --mountpoint "${DATA_ROOT}" >/dev/null

echo '> Creating the appliance directories ...'
# 0750 root:root: the rendered .env and the OAuth2 client secrets live here,
# and unlike the NetBox appliance there is no peer-authentication trick to
# avoid having passwords at all - containers reach PostgreSQL over TCP.
install -d -m 0750 -o root -g root "${CONFIG_DIR}"
install -d -m 0750 -o root -g root "${PROJECT_DIR}"
install -d -m 0755 -o root -g root "${PROJECT_DIR}/nginx"
install -d -m 0750 -o root -g root "${PROJECT_DIR}/oauth2" "${PROJECT_DIR}/oauth2/client"
install -d -m 0755 -o root -g root /var/lib/diode-appliance
install -d -m 0700 -o root -g root "${BACKUP_DIR}"
# The documented path keeps working, as it does on the NetBox appliance.
if [ ! -L /var/backups/diode ]; then
	rm -rf /var/backups/diode
	ln -s "${BACKUP_DIR}" /var/backups/diode
fi

echo '> Installing the compose project ...'
install -m 0640 -o root -g root \
	"${PAYLOAD_DIR}/compose/docker-compose.yaml" "${PROJECT_DIR}/docker-compose.yaml"
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/compose/nginx/nginx.conf" "${PROJECT_DIR}/nginx/nginx.conf"
install -m 0640 -o root -g root \
	"${PAYLOAD_DIR}/compose/env.template" "${CONFIG_DIR}/env.template"
install -m 0640 -o root -g root \
	"${PAYLOAD_DIR}/compose/oauth2/client/client-credentials.json.template" \
	"${CONFIG_DIR}/client-credentials.json.template"

# The reconciler bind-mounts this path. Docker creates a DIRECTORY at a bind
# source that does not exist, which would make SSL_CERT_FILE point at a
# directory and fail in a thoroughly unhelpful way, so the placeholder has to
# exist in the image. It stays empty unless the deploy form supplies a CA.
install -m 0644 -o root -g root /dev/null "${CONFIG_DIR}/netbox-ca.pem"

echo "> Pinning the Diode release to ${DIODE_VERSION} ..."
sed -i "s|__DIODE_TAG__|${DIODE_VERSION}|" "${CONFIG_DIR}/env.template"
if grep -q '__DIODE_TAG__' "${CONFIG_DIR}/env.template"; then
	echo '> the Diode tag placeholder was not substituted'
	exit 1
fi

echo '> Rendering a throwaway build-time environment ...'
# Every secret here exists only for the duration of the build. finalize.sh
# deletes this file, the client credentials and the named volumes the stack
# creates with them, so a deployed appliance starts from nothing.
render_build_env() {
	local out="$1"
	install -m 0600 -o root -g root /dev/null "${out}"
	sed -e "s|__REDIS_PASSWORD__|$(openssl rand -hex 24)|" \
		-e "s|__POSTGRES_PASSWORD__|$(openssl rand -hex 24)|" \
		-e "s|__DIODE_POSTGRES_PASSWORD__|$(openssl rand -hex 24)|" \
		-e "s|__HYDRA_POSTGRES_PASSWORD__|$(openssl rand -hex 24)|" \
		-e "s|__HYDRA_SYSTEM_SECRET__|$(openssl rand -hex 24)|" \
		-e "s|__DIODE_TO_NETBOX_CLIENT_SECRET__|${build_to_netbox_secret}|" \
		-e "s|__NETBOX_PLUGIN_API_BASE_URL__|http://127.0.0.1:65535/api/plugins/diode|" \
		-e "s|__NETBOX_SKIP_TLS_VERIFY__|false|" \
		-e "s|__SSL_CERT_FILE__||" \
		"${CONFIG_DIR}/env.template" >"${out}"
	if grep -q '__[A-Z_]*__' "${out}"; then
		echo '> unsubstituted placeholders remain in the build environment:'
		grep -n '__[A-Z_]*__' "${out}"
		exit 1
	fi
}
build_to_netbox_secret="$(openssl rand -hex 24)"
render_build_env "${PROJECT_DIR}/.env"

install -m 0600 -o root -g root /dev/null "${PROJECT_DIR}/oauth2/client/client-credentials.json"
sed -e "s|__DIODE_INGEST_CLIENT_SECRET__|$(openssl rand -hex 24)|" \
	-e "s|__DIODE_TO_NETBOX_CLIENT_SECRET__|${build_to_netbox_secret}|" \
	-e "s|__NETBOX_TO_DIODE_CLIENT_SECRET__|$(openssl rand -hex 24)|" \
	"${CONFIG_DIR}/client-credentials.json.template" \
	>"${PROJECT_DIR}/oauth2/client/client-credentials.json"
jq -e 'length == 3' "${PROJECT_DIR}/oauth2/client/client-credentials.json" >/dev/null

echo '> Pulling the container images onto the data disk ...'
# --ignore-buildable so a compose file that ever grows a build: section does
# not turn a pull into a build on the appliance.
docker compose --project-directory "${PROJECT_DIR}" pull --ignore-buildable

echo '> Recording the resolved image digests ...'
# The tags in .env say what was asked for; this says what was actually
# received. diode-status reports drift from it and diode-upgrade rewrites it,
# so "which images is this appliance running" has an answer that does not
# depend on a registry being reachable.
{
	echo "# Resolved at build time for Diode ${DIODE_VERSION}. Do not edit by hand."
	docker compose --project-directory "${PROJECT_DIR}" config --images |
		sort -u |
		while read -r image; do
			digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null || true)"
			printf '%s\t%s\n' "${image}" "${digest:-<none>}"
		done
} >"${CONFIG_DIR}/images.lock"
chown root:root "${CONFIG_DIR}/images.lock"
chmod 0644 "${CONFIG_DIR}/images.lock"
cat "${CONFIG_DIR}/images.lock"

echo '> Diode compose project installed.'
