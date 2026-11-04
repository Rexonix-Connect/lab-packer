#!/bin/bash
# The Bitwarden Directory Connector CLI (bwdc), shipped in the image so that an
# appliance can sync its organization's members and groups from Microsoft
# Entra ID without fetching anything after deployment - an air-gapped site
# never reaches GitHub. Pinned by release and by the sha256 of the release
# asset, like the Vaultwarden image: a tag can be re-cut, a digest cannot.
#
# Nothing is configured here. The sync account, the units and the operator
# command are installed; `vaultwarden-dirsync setup` on a deployed appliance
# does the rest, once an organization exists to hold the API key.
set -euo pipefail

: "${DIRECTORY_CONNECTOR_VERSION:?}"
: "${DIRECTORY_CONNECTOR_SHA256:?}"
: "${PAYLOAD_DIR:?}"

INSTALL_DIR=/opt/bitwarden-directory-connector
SERVICE_USER=vaultwarden-dirsync
SERVICE_HOME=/var/lib/vaultwarden-dirsync
ASSET="bwdc-linux-${DIRECTORY_CONNECTOR_VERSION}.zip"
URL="https://github.com/bitwarden/directory-connector/releases/download/v${DIRECTORY_CONNECTOR_VERSION}/${ASSET}"

echo "> Creating the ${SERVICE_USER} account ..."
# Owns nothing but its own state directory and runs nothing but the sync.
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
	adduser --system --group --home "${SERVICE_HOME}" --no-create-home \
		--shell /usr/sbin/nologin "${SERVICE_USER}"
fi
install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${SERVICE_HOME}"
install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${SERVICE_HOME}/appdata"

echo "> Fetching Directory Connector ${DIRECTORY_CONNECTOR_VERSION} ..."
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
curl -sSfL --retry 5 --retry-delay 10 -o "${work}/${ASSET}" "${URL}"
echo "${DIRECTORY_CONNECTOR_SHA256}  ${work}/${ASSET}" | sha256sum --check --strict --quiet || {
	echo "> ${ASSET} does not match the pinned sha256; refusing to install it" >&2
	sha256sum "${work}/${ASSET}" >&2
	exit 1
}
echo "> sha256 verified."

# The zip holds exactly two files, and bwdc requires its native module next to
# the executable. Extracted with python's zipfile - unzip is not in the image
# and this is the only archive it would ever open - and given their modes
# explicitly, since zipfile does not restore them.
install -d -m 0755 -o root -g root "${INSTALL_DIR}"
python3 - "${work}/${ASSET}" "${INSTALL_DIR}" <<'PY'
import os
import sys
import zipfile

archive, target = sys.argv[1], sys.argv[2]
expected = {"bwdc", "dc_native.linux-x64-gnu.node"}
with zipfile.ZipFile(archive) as zf:
    names = set(zf.namelist())
    if names != expected:
        sys.exit("unexpected archive contents: %s" % sorted(names))
    for name in sorted(names):
        with zf.open(name) as src, open(os.path.join(target, name), "wb") as dst:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                dst.write(chunk)
PY
chmod 0755 "${INSTALL_DIR}/bwdc" "${INSTALL_DIR}/dc_native.linux-x64-gnu.node"
chown root:root "${INSTALL_DIR}"/*
echo "${DIRECTORY_CONNECTOR_VERSION}" >"${INSTALL_DIR}/VERSION"
chmod 0644 "${INSTALL_DIR}/VERSION"

echo '> Verifying bwdc runs as the sync account ...'
# As the account and against a throwaway state directory: bwdc writes its
# data.json on first use, and it must not do so in /root or in the real one.
scratch="$(mktemp -d)"
chown "${SERVICE_USER}:${SERVICE_USER}" "${scratch}"
reported="$(runuser -u "${SERVICE_USER}" -- env \
	HOME="${scratch}" \
	BITWARDENCLI_CONNECTOR_APPDATA_DIR="${scratch}" \
	BITWARDENCLI_CONNECTOR_PLAINTEXT_SECRETS=true \
	"${INSTALL_DIR}/bwdc" --version | tr -d '[:space:]')"
rm -rf "${scratch}"
if [ "${reported}" != "${DIRECTORY_CONNECTOR_VERSION}" ]; then
	echo "> bwdc --version reported '${reported}', expected ${DIRECTORY_CONNECTOR_VERSION}" >&2
	exit 1
fi
echo "> bwdc ${reported}"

echo '> Installing the sync units (disabled until configured) ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/vaultwarden-dirsync.service" /etc/systemd/system/vaultwarden-dirsync.service
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/vaultwarden-dirsync.timer" /etc/systemd/system/vaultwarden-dirsync.timer
systemctl daemon-reload
systemctl disable vaultwarden-dirsync.timer >/dev/null 2>&1 || true
# A unit file systemd cannot parse is only reported when it starts; check now.
systemd-analyze verify /etc/systemd/system/vaultwarden-dirsync.service \
	/etc/systemd/system/vaultwarden-dirsync.timer
echo '> Directory Connector installed.'
