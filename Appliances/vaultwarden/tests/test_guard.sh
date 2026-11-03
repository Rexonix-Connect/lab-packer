#!/bin/bash
# Check every way vaultwarden-guard has to refuse - and the two ways it must
# not. The guard is the one thing between a missing data disk and a healthy-
# looking, empty password manager, so each refusal is asserted, not assumed.
#
# findmnt, runuser, pg_isready and curl are stubbed on PATH; the data root,
# config and state directories are temporary ones. No appliance, no root.
#
#     bash Appliances/vaultwarden/tests/test_guard.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/../files/vaultwarden-appliance/bin/vaultwarden-guard"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
check() { # check <label> <exit status> <expected status>
	if [ "${2}" -eq "${3}" ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s (exit %s, expected %s)\n' "${1}" "${2}" "${3}"
		failures=$((failures + 1))
	fi
}

mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/findmnt" <<'EOF'
#!/bin/bash
[ "${FAKE_MOUNTED:-yes}" = 'yes' ]
EOF
cat >"${WORK}/bin/pg_isready" <<'EOF'
#!/bin/bash
exit 0
EOF
# runuser -u vaultwarden -- psql ... -c "<sql>": answer the two queries the
# guard asks.
cat >"${WORK}/bin/runuser" <<'EOF'
#!/bin/bash
sql="${*: -1}"
case "${sql}" in
'SELECT 1') echo 1 ;;
*to_regclass*) echo "${FAKE_SCHEMA:-f}" ;;
*) exit 1 ;;
esac
EOF
cat >"${WORK}/bin/curl" <<'EOF'
#!/bin/bash
printf 200
EOF
chmod +x "${WORK}/bin/"*
export PATH="${WORK}/bin:${PATH}"

export VAULTWARDEN_DATA_ROOT="${WORK}/srv"
export VAULTWARDEN_CONFIG_DIR="${WORK}/etc"
export VAULTWARDEN_APPLIANCE_STATE_DIR="${WORK}/state"

reset() {
	rm -rf "${WORK}/srv" "${WORK}/etc" "${WORK}/state"
	mkdir -p "${WORK}/srv/data" "${WORK}/etc" "${WORK}/state"
	echo 'vol-1' >"${WORK}/etc/volume-id"
	echo 'vol-1' >"${WORK}/srv/.volume-id"
	unset FAKE_MOUNTED FAKE_SCHEMA
}

guard() { bash "${GUARD}" "$@" >/dev/null 2>&1; }

reset
guard pre-start
check 'first start on a fresh, matching disk is allowed' $? 0

reset
export FAKE_MOUNTED=no
guard pre-start
check 'refuses when the data disk is not mounted' $? 1

reset
rm "${WORK}/srv/.volume-id"
guard pre-start
check 'refuses a blank disk with no volume id' $? 1

reset
echo 'vol-2' >"${WORK}/srv/.volume-id"
guard pre-start
check "refuses another deployment's disk" $? 1

reset
rm -r "${WORK}/srv/data"
guard pre-start
check 'refuses when the data directory is missing' $? 1

reset
: >"${WORK}/state/initialized"
export FAKE_SCHEMA=f
guard pre-start
check 'refuses an initialized appliance whose database lost its schema' $? 1

reset
: >"${WORK}/state/initialized"
export FAKE_SCHEMA=t
guard pre-start
check 'refuses an initialized appliance whose signing key is gone' $? 1

reset
: >"${WORK}/state/initialized"
export FAKE_SCHEMA=t
: >"${WORK}/srv/data/rsa_key.pem"
guard pre-start
check 'starts an initialized appliance with schema and key' $? 0

# The root disk was rebuilt from the template (no marker) and the old data
# disk, signing key intact, lost its database: the disk's own evidence must
# be enough to refuse.
reset
export FAKE_SCHEMA=f
: >"${WORK}/srv/data/rsa_key.pem"
guard pre-start
check 'refuses a data disk with a signing key but no schema, with no root-disk marker' $? 1

reset
export FAKE_SCHEMA=t
: >"${WORK}/srv/data/rsa_key.pem"
guard post-start
check 'post-start succeeds once /alive answers' $? 0
[ -f "${WORK}/state/initialized" ]
check 'post-start marks the deployment initialized' $? 0

reset
export FAKE_SCHEMA=f
guard post-start
[ ! -f "${WORK}/state/initialized" ]
check 'post-start does not mark it without a schema' $? 0

if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed"
	exit 1
fi
