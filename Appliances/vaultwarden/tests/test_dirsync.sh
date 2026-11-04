#!/bin/bash
# vaultwarden-dirsync against a fake bwdc: the configuration it renders for
# the pinned Directory Connector, where the secrets go (and where they must
# not), the state it records for vaultwarden-status, and every refusal.
#
# bwdc, systemctl, runuser, getent, id, chown and install are stubbed on PATH;
# the state directories are temporary. No appliance, no root, no Entra.
#
#     bash Appliances/vaultwarden/tests/test_dirsync.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${HERE}/../files/vaultwarden-appliance/bin/vaultwarden-dirsync"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
check() { # check <label> <expected> <actual> [detail]
	if [ "${2}" = "${3}" ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s -- expected %s, got %s%s\n' "${1}" "${2}" "${3}" "${4:+ ($4)}"
		failures=$((failures + 1))
	fi
}

REAL_USER="$(id -un)"
REAL_INSTALL="$(command -v install)"
ENTRA_SECRET='entra-secret-Qx9~zz'
# Shell-significant characters on purpose: the file holding it is sourced.
ORG_SECRET='org-secret-Ww3!yy$x "q" '"'"'single'"'"' `tick`'

#
# Stubs.
#
mkdir -p "${WORK}/bin" "${WORK}/fake"
FAKE_LOG="${WORK}/bwdc.log"
SYSTEMCTL_LOG="${WORK}/systemctl.log"

# The connector: records every call, answers like the real one (--response
# JSON), and keeps its state in data.json under its appdata directory, in the
# flat 2026.x layout.
cat >"${WORK}/fake/bwdc" <<'EOF'
#!/bin/bash
set -u
[ "${BITWARDENCLI_CONNECTOR_PLAINTEXT_SECRETS:-}" = 'true' ] || { echo 'plaintext secrets not enabled' >&2; exit 97; }
[ -n "${BITWARDENCLI_CONNECTOR_APPDATA_DIR:-}" ] || { echo 'no appdata dir' >&2; exit 97; }
data="${BITWARDENCLI_CONNECTOR_APPDATA_DIR}/data.json"
args=()
for a in "$@"; do
	case "${a}" in
	--response | --quiet | --nointeraction | --pretty | --raw) ;;
	*) args+=("${a}") ;;
	esac
done
set -- "${args[@]}"
# The log holds the command and its arguments, flags stripped: what the
# checks read back, and where a secret must never turn up.
printf '%s\n' "$*" >>"${FAKE_LOG}"
# Paths go through argv, never into the expression: the test also runs on Git
# Bash, where only argv paths are translated for a native python.
edit() { # edit <python expression over data> [file available as argv[3]]
	python3 - "${data}" "$1" "${2:-}" <<'PY'
import json, os, sys
path, expr = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as fh:
        data = json.load(fh)
exec(expr)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
}
case "${1:-}" in
--version) echo '2026.10.0' ;;
config)
	case "${2:-}" in
	server) edit "data['environmentUrls'] = {'base': '$3'}; data['stateVersion'] = 9" ;;
	directory) edit "data['directoryType'] = int('$3'); data.setdefault('directoryEntra', {'id': 'cfg-1'}); data.setdefault('sync', {'users': False, 'groups': False, 'interval': 5})" ;;
	entra.key)
		if [ "${3:-}" = '--secretfile' ]; then
			edit "data['directoryEntra']['key'] = open(sys.argv[3]).readline().rstrip('\n')" "$4"
		else
			echo "SECRET-ON-COMMAND-LINE" >>"${FAKE_LOG}"
			edit "data['directoryEntra']['key'] = '$3'"
		fi
		;;
	sync.inviteusersafterprovisioning) edit "data['sync']['inviteUsersAfterProvisioning'] = ('$3' == 'true')" ;;
	*) echo '{"success":false,"message":"Unknown setting."}'; exit 1 ;;
	esac
	;;
login)
	if [ "${FAKE_LOGIN_FAIL:-}" = '1' ]; then
		echo '{"success":false,"message":"Invalid client."}'
		exit 1
	fi
	[ -n "${BW_CLIENTID:-}" ] && [ -n "${BW_CLIENTSECRET:-}" ] || { echo '{"success":false,"message":"Client ID is required."}'; exit 1; }
	echo "apikey-via-env ${BW_CLIENTID}" >>"${FAKE_LOG}"
	echo '{"success":true,"data":{"object":"message","title":"You are logged in!"}}'
	;;
test)
	echo '{"success":true,"data":{"object":"test","groups":[{"name":"Vault Users","externalId":"g1"},{"name":"Vault Admins","externalId":"g2"}],"enabledUsers":[{"email":"a@example.com"},{"email":"b@example.com"},{"email":"c@example.com"}],"disabledUsers":[{"email":"d@example.com"}],"deletedUsers":[]}}'
	;;
sync)
	if [ "${FAKE_SYNC_FAIL:-}" = '1' ]; then
		echo '{"success":false,"message":"Request failed: 500 Internal Server Error"}'
		exit 1
	fi
	echo '{"success":true,"data":{"object":"message","title":"Syncing complete.","message":"2 groups and 3 users synced."}}'
	;;
logout) exit "${FAKE_LOGOUT_RC:-0}" ;;
clear-cache) echo '{"success":true,"data":{"object":"message","title":"Sync cache cleared."}}' ;;
*) echo "{\"success\":false,\"message\":\"Invalid command: $*\"}"; exit 1 ;;
esac
EOF
echo '2026.10.0' >"${WORK}/fake/VERSION"

# systemctl: the timer's enabled state is a file; starting the service runs
# the command's own `run`, as the unit would.
cat >"${WORK}/bin/systemctl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"${SYSTEMCTL_LOG}"
case "\$1" in
start) [ "\$2" = 'vaultwarden-dirsync.service' ] && exec bash "${CLI}" run; exit 0 ;;
enable) echo enabled >"${WORK}/timer.state" ;;
disable) echo disabled >"${WORK}/timer.state" ;;
is-enabled) cat "${WORK}/timer.state" 2>/dev/null || { echo disabled; exit 1; } ;;
is-active) [ "\$(cat "${WORK}/timer.state" 2>/dev/null)" = enabled ] && echo active || { echo inactive; exit 3; } ;;
show) echo 'Tue 2026-11-04 12:00:00 UTC' ;;
esac
exit 0
EOF
cat >"${WORK}/bin/runuser" <<'EOF'
#!/bin/bash
# runuser -u <user> -- <command...>
shift 3
exec "$@"
EOF
cat >"${WORK}/bin/getent" <<'EOF'
#!/bin/bash
[ "${FAKE_NO_DNS:-}" = '1' ] && exit 2
echo "192.0.2.10 $2"
EOF
cat >"${WORK}/bin/id" <<EOF
#!/bin/bash
case "\${1:-}" in
-u) echo 0 ;;
-un) echo '${REAL_USER}' ;;
*) echo 0 ;;
esac
EOF
cat >"${WORK}/bin/chown" <<'EOF'
#!/bin/bash
exit 0
EOF
# install without the ownership flags, which need root - and, on Git Bash for
# Windows only, without the mode, which its /tmp refuses; directory modes are
# not what this test asserts.
cat >"${WORK}/bin/install" <<EOF
#!/bin/bash
args=()
while [ \$# -gt 0 ]; do
	case "\$1" in
	-o | -g) shift 2 ;;
	-m) if [ -n "\${MSYSTEM:-}" ]; then shift 2; else args+=("\$1" "\$2"); shift 2; fi ;;
	*) args+=("\$1"); shift ;;
	esac
done
exec "${REAL_INSTALL}" "\${args[@]}"
EOF
chmod +x "${WORK}/bin/"* "${WORK}/fake/bwdc"
export PATH="${WORK}/bin:${PATH}"
export FAKE_LOG

#
# A stand-in appliance.
#
mkdir -p "${WORK}/appliance" "${WORK}/secrets"
printf '{"url": "https://vault.example.com", "fqdn": "vault.example.com", "org_groups": false}\n' \
	>"${WORK}/appliance/state.json"
printf '%s\n' "${ENTRA_SECRET}" >"${WORK}/secrets/entra"
printf '%s\n' "${ORG_SECRET}" >"${WORK}/secrets/org"
: >"${WORK}/ca.crt"

export VAULTWARDEN_DIRSYNC_ROOT="${WORK}/dirsync"
export VAULTWARDEN_DIRSYNC_BWDC="${WORK}/fake/bwdc"
export VAULTWARDEN_DIRSYNC_USER="${REAL_USER}"
export VAULTWARDEN_APPLIANCE_STATE_DIR="${WORK}/appliance"
export VAULTWARDEN_DIRSYNC_TIMER_DROPIN="${WORK}/timer.d/10-interval.conf"
export VAULTWARDEN_TLS_CERT="${WORK}/ca.crt"
mkdir -p "${VAULTWARDEN_DIRSYNC_ROOT}/appdata"

dirsync() { bash "${CLI}" "$@"; }
# The bwdc verbs the fake was driven with, in order.
sequence() {
	sed -nE 's/^(config [a-z.]+|login|test|sync|logout|clear-cache)( .*)?$/\1/p' "${FAKE_LOG}" | tr '\n' ' '
}
# File modes are asserted on Linux only: Git Bash for Windows reports NTFS
# permissions as 644 whatever chmod was asked for.
mode_check() { # mode_check <label> <file> <expected>
	if [ -n "${MSYSTEM:-}" ]; then
		printf 'skip %s (not on Windows)\n' "${1}"
	else
		check "${1}" "${3}" "$(stat -c %a "${2}")"
	fi
}
field() { # field <json file> <dotted key>
	python3 -c '
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    value = value[key]
print(str(value).lower() if isinstance(value, bool) else value)' "$1" "$2" 2>/dev/null
}
reset() {
	rm -rf "${VAULTWARDEN_DIRSYNC_ROOT}" "${WORK}/timer.d" "${WORK}/timer.state"
	mkdir -p "${VAULTWARDEN_DIRSYNC_ROOT}/appdata"
	: >"${FAKE_LOG}"
	: >"${SYSTEMCTL_LOG}"
	unset FAKE_LOGIN_FAIL FAKE_SYNC_FAIL FAKE_NO_DNS FAKE_LOGOUT_RC
}
DATA="${VAULTWARDEN_DIRSYNC_ROOT}/appdata/data.json"
CREDENTIALS="${VAULTWARDEN_DIRSYNC_ROOT}/credentials.env"
STATE="${VAULTWARDEN_DIRSYNC_ROOT}/state.json"
setup_args=(--tenant contoso.onmicrosoft.com
	--application-id 11111111-2222-3333-4444-555555555555
	--org-client-id organization.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
	--entra-secret-file "${WORK}/secrets/entra"
	--org-secret-file "${WORK}/secrets/org"
	--yes)

#
# Before setup.
#
reset
output="$(dirsync status)"
check "status before setup says so and succeeds" 0 "$?" "${output}"
grep -q 'not configured' <<<"${output}"
check "status before setup names the setup command" 0 "$?"
dirsync run >/dev/null 2>&1
check "run refuses when nothing is configured" 2 "$?"
dirsync sync >/dev/null 2>&1
check "sync refuses when nothing is configured" 2 "$?"
dirsync enable >/dev/null 2>&1
check "enable refuses when nothing is configured" 2 "$?"
dirsync >/dev/null 2>&1
check "no arguments is a usage error" 2 "$?"

#
# Validation, before anything is written.
#
reset
dirsync setup "${setup_args[@]}" --org-client-id 'not-an-org-key' >/dev/null 2>&1
check "a malformed organization client id is refused" 2 "$?"
dirsync setup "${setup_args[@]}" --application-id 'abc' >/dev/null 2>&1
check "a malformed application id is refused" 2 "$?"
dirsync setup "${setup_args[@]}" --interval 3 >/dev/null 2>&1
check "an interval under 5 minutes is refused" 2 "$?"
dirsync setup "${setup_args[@]}" --bogus >/dev/null 2>&1
check "an unknown option is refused" 2 "$?"
output="$(dirsync setup "${setup_args[@]}" --groups 2>&1)"
check "--groups is refused while the appliance has groups off" 1 "$?"
grep -q 'vaultwarden.org-groups' <<<"${output}"
check "  and says which deploy-form property turns them on" 0 "$?" "${output}"
[ ! -e "${CREDENTIALS}" ]
check "  nothing was written" 0 "$?"
FAKE_NO_DNS=1 output="$(FAKE_NO_DNS=1 dirsync setup "${setup_args[@]}" 2>&1)"
check "an unresolvable appliance name is refused before any secret is read" 1 "$?"
grep -q 'does not resolve' <<<"${output}"
check "  and says so" 0 "$?" "${output}"

#
# The happy path.
#
reset
output="$(dirsync setup "${setup_args[@]}" 2>&1)"
check "setup succeeds" 0 "$?" "${output}"
check "directory type is Entra ID (1)" 1 "$(field "${DATA}" directoryType)"
check "tenant rendered" contoso.onmicrosoft.com "$(field "${DATA}" directoryEntra.tenant)"
check "application id rendered" 11111111-2222-3333-4444-555555555555 "$(field "${DATA}" directoryEntra.applicationId)"
check "public identity authority" login.microsoftonline.com "$(field "${DATA}" directoryEntra.identityAuthority)"
check "the configuration id bwdc assigned survives the edit" cfg-1 "$(field "${DATA}" directoryEntra.id)"
check "the Entra secret reached bwdc through its secret file" "${ENTRA_SECRET}" "$(field "${DATA}" directoryEntra.key)"
check "server URL is the appliance's own" https://vault.example.com "$(field "${DATA}" environmentUrls.base)"
check "users are synced" true "$(field "${DATA}" sync.users)"
check "groups are off by default" false "$(field "${DATA}" sync.groups)"
check "disabled accounts are revoked by default" true "$(field "${DATA}" sync.removeDisabled)"
check "members are not removed by default" false "$(field "${DATA}" sync.overwriteExisting)"
check "large import off by default" false "$(field "${DATA}" sync.largeImport)"
check "invitations are sent" true "$(field "${DATA}" sync.inviteUsersAfterProvisioning)"
check "interval defaults to 15" 15 "$(field "${DATA}" sync.interval)"
grep -qx "BW_CLIENTID=organization.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "${CREDENTIALS}"
check "credentials file holds the organization client id" 0 "$?"
[ "$(bash -c ". '${CREDENTIALS}'; printf '%s' \"\${BW_CLIENTSECRET}\"")" = "${ORG_SECRET}" ]
check "credentials file holds the organization secret, intact when sourced" 0 "$?" "$(cat "${CREDENTIALS}")"
mode_check "credentials file is private" "${CREDENTIALS}" 600
grep -q 'SECRET-ON-COMMAND-LINE' "${FAKE_LOG}"
check "the Entra secret was never a bwdc argument" 1 "$?"
grep -qF "${ENTRA_SECRET}" "${FAKE_LOG}"
check "the Entra secret appears in no bwdc argument list" 1 "$?"
grep -qF "${ORG_SECRET}" "${FAKE_LOG}"
check "the organization secret appears in no bwdc argument list" 1 "$?"
grep -qF "${ORG_SECRET}" <<<"${output}"
check "the organization secret is not in setup's output" 1 "$?"
grep -qF "${ENTRA_SECRET}" <<<"${output}"
check "the Entra secret is not in setup's output" 1 "$?"
grep -q 'apikey-via-env organization.aaaaaaaa' "${FAKE_LOG}"
check "bwdc login got the API key from its environment" 0 "$?"
check "bwdc was driven in order" \
	'config server config directory config entra.key config sync.inviteusersafterprovisioning login test login sync logout ' \
	"$(sequence)"
grep -q 'Users to invite *3' <<<"${output}"
check "the directory test summary is shown" 0 "$?" "${output}"
grep -q 'b@example.com' <<<"${output}"
check "  with the addresses it would invite" 0 "$?"
grep -q 'enable --now vaultwarden-dirsync.timer' "${SYSTEMCTL_LOG}"
check "the timer was enabled after the first sync" 0 "$?"
grep -qx 'OnUnitActiveSec=15min' "${WORK}/timer.d/10-interval.conf"
check "the interval drop-in was written" 0 "$?"
check "the first sync recorded a success" 0 "$(field "${STATE}" consecutive_failures)"
check "  with the group count" 2 "$(field "${STATE}" groups)"
check "  and the user count" 3 "$(field "${STATE}" users)"
mode_check "state file is private" "${STATE}" 600

output="$(dirsync status)"
check "status after setup succeeds" 0 "$?"
grep -q 'contoso.onmicrosoft.com' <<<"${output}" && grep -q 'Last success 2' <<<"${output}" &&
	grep -q 'enabled/active, every 15 min' <<<"${output}"
check "status shows tenant, last success and the timer" 0 "$?" "${output}"
grep -qF "${ORG_SECRET}" <<<"${output}" || grep -qF "${ENTRA_SECRET}" <<<"${output}"
check "status shows no secret" 1 "$?"

#
# Failures are recorded, counted and reported.
#
: >"${FAKE_LOG}"
FAKE_SYNC_FAIL=1 dirsync run >/dev/null 2>&1
check "a failed sync fails the run" 1 "$?"
check "  and counts one failure" 1 "$(field "${STATE}" consecutive_failures)"
grep -q 'sync failed: Request failed: 500' <<<"$(field "${STATE}" last_message)"
check "  with bwdc's message" 0 "$?" "$(field "${STATE}" last_message)"
grep -q '^logout' "${FAKE_LOG}"
check "  and still logs out" 0 "$?"
FAKE_SYNC_FAIL=1 dirsync run >/dev/null 2>&1
check "  a second failure counts two" 2 "$(field "${STATE}" consecutive_failures)"
output="$(dirsync status)"
grep -q 'LAST RUN FAILED (2 in a row' <<<"${output}"
check "status reports the failure streak" 0 "$?" "${output}"
FAKE_SYNC_FAIL=1 dirsync sync >/dev/null 2>&1
check "sync through the unit reports the failure" 1 "$?"
dirsync run >/dev/null 2>&1
check "a good run succeeds again" 0 "$?"
check "  and resets the streak" 0 "$(field "${STATE}" consecutive_failures)"
FAKE_LOGIN_FAIL=1 dirsync run >/dev/null 2>&1
check "a failed login fails the run" 1 "$?"
grep -q 'login failed: Invalid client' <<<"$(field "${STATE}" last_message)"
check "  and says it was the login" 0 "$?"
FAKE_LOGOUT_RC=1 dirsync run >/dev/null 2>&1
check "a failing logout (bwdc 2026.10.0) does not fail a good sync" 0 "$?"

#
# resync, enable, disable, bwdc passthrough, remove.
#
: >"${FAKE_LOG}"
dirsync resync >/dev/null 2>&1
check "resync succeeds" 0 "$?"
check "resync clears the cache before syncing" 'clear-cache login sync logout ' "$(sequence)"
dirsync disable >/dev/null 2>&1
check "disable succeeds" 0 "$?"
check "  the timer is disabled" disabled "$(cat "${WORK}/timer.state")"
dirsync enable >/dev/null 2>&1
check "enable succeeds" 0 "$?"
check "  the timer is enabled" enabled "$(cat "${WORK}/timer.state")"
output="$(dirsync bwdc -- --version)"
check "bwdc passthrough runs bwdc" '2026.10.0' "${output}"
dirsync remove --yes >/dev/null 2>&1
check "remove succeeds" 0 "$?"
[ ! -e "${CREDENTIALS}" ] && [ ! -e "${DATA}" ] && [ ! -e "${STATE}" ] && [ ! -e "${WORK}/timer.d/10-interval.conf" ]
check "  the configuration, secrets, state and drop-in are gone" 0 "$?"
[ -d "${VAULTWARDEN_DIRSYNC_ROOT}/appdata" ]
check "  the appdata directory is kept for the next setup" 0 "$?"
check "  the timer is disabled" disabled "$(cat "${WORK}/timer.state")"
output="$(dirsync status)"
grep -q 'not configured' <<<"${output}"
check "status is back to not configured" 0 "$?" "${output}"

#
# Options, and a failed login during setup.
#
reset
printf '{"url": "https://vault.example.com", "fqdn": "vault.example.com", "org_groups": true}\n' \
	>"${WORK}/appliance/state.json"
dirsync setup "${setup_args[@]}" --groups --interval 30 --overwrite-existing --keep-disabled \
	--large-import --user-filter 'includeGroup:0f0f0f0f-1111-2222-3333-444444444444' \
	--group-filter 'include:Vault Users,Vault Admins' >/dev/null 2>&1
check "setup with every option succeeds when groups are on" 0 "$?"
check "groups are synced" true "$(field "${DATA}" sync.groups)"
check "interval 30" 30 "$(field "${DATA}" sync.interval)"
grep -qx 'OnUnitActiveSec=30min' "${WORK}/timer.d/10-interval.conf"
check "  and the drop-in follows it" 0 "$?"
check "members missing from the directory are removed" true "$(field "${DATA}" sync.overwriteExisting)"
check "disabled accounts are kept" false "$(field "${DATA}" sync.removeDisabled)"
check "large import" true "$(field "${DATA}" sync.largeImport)"
check "user filter" 'includeGroup:0f0f0f0f-1111-2222-3333-444444444444' "$(field "${DATA}" sync.userFilter)"
check "group filter" 'include:Vault Users,Vault Admins' "$(field "${DATA}" sync.groupFilter)"

reset
output="$(FAKE_LOGIN_FAIL=1 dirsync setup "${setup_args[@]}" 2>&1)"
check "setup fails when the organization login fails" 1 "$?"
grep -q 'login failed: Invalid client' <<<"${output}"
check "  with bwdc's reason" 0 "$?" "${output}"
[ ! -e "${CREDENTIALS}" ]
check "  and leaves no credentials behind" 0 "$?"
grep -q 'enable' "${SYSTEMCTL_LOG}"
check "  and does not enable the timer" 1 "$?"

echo
if [ "${failures}" -ne 0 ]; then
	echo "${failures} FAILURE(S)"
	exit 1
fi
echo "ALL CHECKS PASSED"
