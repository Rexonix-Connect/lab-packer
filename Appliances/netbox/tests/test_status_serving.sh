#!/bin/bash
# Check how netbox-status decides whether the appliance is serving.
#
# The probe used to be a single five-second request. A cold gunicorn - after a
# restart, or a boot with several plugins loading - answers its first request
# more slowly than that, so a healthy appliance reported
#
#     Serving   NO (HTTP 000)
#
# on the console and in the MOTD, and made netbox-upgrade and netbox-restore
# (which end by running this under set -e) look like they had failed. Measured
# on a four-plugin appliance: 5.4s cold, 0.01s warm.
#
# curl and systemctl are stubbed on PATH; the state directory is a temporary
# one via NETBOX_APPLIANCE_STATE_DIR. No appliance, no NetBox, no root.
#
#     bash Appliances/netbox/tests/test_status_serving.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="${HERE}/../files/netbox-appliance/bin/netbox-status"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
check() { # check <label> <condition-exit> [detail]
	if [ "${2}" -eq 0 ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s%s\n' "${1}" "${3:+ -- $3}"
		failures=$((failures + 1))
	fi
}

export NETBOX_APPLIANCE_STATE_DIR="${WORK}/state"
mkdir -p "${NETBOX_APPLIANCE_STATE_DIR}"
: >"${NETBOX_APPLIANCE_STATE_DIR}/bootstrapped"
cat >"${NETBOX_APPLIANCE_STATE_DIR}/state.json" <<'EOF'
{"netbox_version": "v4.6.7", "url": "https://netbox.example.com/",
 "database": "local", "self_signed_certificate": false}
EOF

mkdir -p "${WORK}/bin"
export PATH="${WORK}/bin:${PATH}"
printf '#!/bin/sh\necho active\n' >"${WORK}/bin/systemctl"
chmod +x "${WORK}/bin/systemctl"

# A curl that answers by script: one line of ${WORK}/answers per call.
cat >"${WORK}/bin/curl" <<EOF
#!/bin/sh
calls="\$(cat "${WORK}/calls" 2>/dev/null || echo 0)"
calls=\$((calls + 1))
echo "\${calls}" >"${WORK}/calls"
printf '%s' "\$(sed -n "\${calls}p" "${WORK}/answers")"
EOF
chmod +x "${WORK}/bin/curl"

run() { # run <answer-per-call>...
	printf '%s\n' "$@" >"${WORK}/answers"
	rm -f "${WORK}/calls"
	output="$(bash "${STATUS}" 2>&1)"
	status="$?"
	calls="$(cat "${WORK}/calls" 2>/dev/null || echo 0)"
}

# Warm: answers immediately, and is not asked twice.
run 200 200
grep -q 'Serving   yes (HTTP 200)' <<<"${output}"
check "a warm appliance is serving" "$?" "${output}"
check "and is asked exactly once" "$([ "${calls}" = 1 ] && echo 0 || echo 1)" \
	"asked ${calls} time(s)"
check "exit status is 0" "${status}"

# Cold: the five-second probe times out, the patient one succeeds. This is the
# case that used to be reported as not serving.
run 000 200
grep -q 'Serving   yes (HTTP 200)' <<<"${output}"
check "a cold start is not reported as down" "$?" "${output}"
check "it took the second, patient probe" \
	"$([ "${calls}" = 2 ] && echo 0 || echo 1)" "asked ${calls} time(s)"
check "exit status is 0" "${status}"

# Genuinely down: both probes fail, and it still says so.
run 000 000
grep -q 'Serving   NO (HTTP 000)' <<<"${output}"
check "an appliance that never answers is still NO" "$?" "${output}"
check "exit status is 1" "$([ "${status}" = 1 ] && echo 0 || echo 1)" \
	"exit ${status}"

# A real error code is reported as itself, not retried into silence.
run 502 502
grep -q 'Serving   NO (HTTP 502)' <<<"${output}"
check "a 502 is reported as 502" "$?" "${output}"

# A plugin that owns the login flow redirects /login/. netbox-otp-plugin does
# exactly this, and an earlier version of the check called it a dead appliance
# and had netbox-plugin uninstall a plugin that was working.
run 302 302
grep -q 'Serving   yes (HTTP 302)' <<<"${output}"
check "a redirect is serving, not a fault" "$?" "${output}"
check "and is not retried" "$([ "${calls}" = 1 ] && echo 0 || echo 1)" \
	"asked ${calls} time(s)"
check "exit status is 0" "${status}"

# 404 is not "answered well enough": something is answering, but not NetBox.
run 404 404
grep -q 'Serving   NO (HTTP 404)' <<<"${output}"
check "a 404 is still NO" "$?" "${output}"

echo
if [ "${failures}" -eq 0 ]; then
	echo "ALL CHECKS PASSED"
	exit 0
fi
echo "${failures} FAILURE(S)"
exit 1
