#!/bin/bash
# netbox-upgrade keeps one line of local_requirements.txt in step with the
# release it installs: the mkdocstrings 1.0.7 pin that works around
# netbox-community/netbox#23376 on NetBox 4.6, which must be present there
# (upgrade.sh rebuilds the venv every run, so nothing else would carry it) and
# must be gone on a release that pins mkdocstrings itself to something newer,
# or it would downgrade that release's own pin.
#
# The function is lifted out of netbox-upgrade by its markers and run against
# a stand-in tree in a temporary directory. No appliance, no NetBox, no root.
#
#     bash Appliances/netbox/tests/test_upgrade_workaround.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HERE}/../files/netbox-appliance/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
check() { # check <label> <expected-exit> <actual-exit> [detail]
	if [ "${2}" = "${3}" ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s -- expected %s, got %s%s\n' "${1}" "${2}" "${3}" \
			"${4:+ ($4)}"
		failures=$((failures + 1))
	fi
}

NETBOX_ROOT="${WORK}/opt/netbox"
mkdir -p "${NETBOX_ROOT}"
requirements="${NETBOX_ROOT}/requirements.txt"
local_requirements="${NETBOX_ROOT}/local_requirements.txt"

# The function and the variables it reads, exactly as netbox-upgrade defines
# them. The markers are part of the contract: moving the block without them
# makes this test fail to find it, which fails the test rather than passing it.
snippet="${WORK}/workaround.sh"
sed -n '/^# --- requirements-workaround begin ---$/,/^# --- requirements-workaround end ---$/p' \
	"${BIN}/netbox-upgrade" >"${snippet}"
grep -q 'reconcile_requirements_workarounds()' "${snippet}"
check "the function was found in netbox-upgrade" 0 "$?"
# shellcheck disable=SC1090
source "${snippet}"

tagged() { grep -c 'lab-packer workaround' "${local_requirements}" 2>/dev/null || true; }

# Build-time shape: the header install-netbox.sh writes, nothing else.
header='# Extra Python packages for this appliance.'

#
# A release that still pins 1.0.6 (every 4.6.x) gets the line.
#
printf 'Django==5.2.11\nmkdocstrings==1.0.6\nzensical==0.0.52\n' >"${requirements}"
printf '%s\n' "${header}" >"${local_requirements}"
workaround_removed=0
reconcile_requirements_workarounds
check "4.6: the 1.0.7 pin is added" 1 "$(tagged)"
grep -qx 'mkdocstrings==1.0.7  # lab-packer workaround: netbox-community/netbox#23376' \
	"${local_requirements}"
check "4.6: the line is a valid pip requirement with the tag as its comment" 0 "$?"
check "4.6: adding is not reported as a removal" 0 "${workaround_removed}"

reconcile_requirements_workarounds
check "4.6: running it again adds nothing" 1 "$(tagged)"
grep -qxF "${header}" "${local_requirements}"
check "4.6: the header is untouched" 0 "$?"

#
# The same when the file does not exist at all.
#
rm -f "${local_requirements}"
reconcile_requirements_workarounds
check "4.6: a missing local_requirements.txt is created with the line" 1 "$(tagged)"

#
# A release that pins something newer (4.7.4 pins 1.0.8) loses the line, and
# only the line: the operator's plugins stay.
#
printf 'Django==5.2.11\nmkdocstrings==1.0.8\npymdown-extensions==12.1\n' >"${requirements}"
printf '%s\nnetbox-bgp==0.17.0\nmkdocstrings==1.0.7  # lab-packer workaround: netbox-community/netbox#23376\nnetbox-topology-views==4.3.1\n' \
	"${header}" >"${local_requirements}"
workaround_removed=0
reconcile_requirements_workarounds
check "4.7: the pin is removed" 0 "$(tagged)"
check "4.7: the removal is reported, for the rollback hint" 1 "${workaround_removed}"
expected="$(printf '%s\nnetbox-bgp==0.17.0\nnetbox-topology-views==4.3.1\n' "${header}")"
[ "$(cat "${local_requirements}")" = "${expected}" ]
check "4.7: the plugins and the header survive, in order" 0 "$?" "$(cat "${local_requirements}")"

#
# A file holding nothing but the workaround ends up empty, not holding a
# blank line that upgrade.sh would then feed to pip.
#
printf 'mkdocstrings==1.0.7  # lab-packer workaround: netbox-community/netbox#23376\n' \
	>"${local_requirements}"
reconcile_requirements_workarounds
[ ! -s "${local_requirements}" ]
check "4.7: a file that held only the pin is left empty" 0 "$?"

#
# Nothing to do, nothing done: no line, no report, and no error from grep on
# a file that is not there.
#
printf '%s\nnetbox-bgp==0.17.0\n' "${header}" >"${local_requirements}"
before="$(cat "${local_requirements}")"
workaround_removed=0
reconcile_requirements_workarounds
[ "$(cat "${local_requirements}")" = "${before}" ]
check "4.7: a file without the pin is not rewritten" 0 "$?"
check "4.7: nothing removed, nothing reported" 0 "${workaround_removed}"
rm -f "${local_requirements}"
( set -e; reconcile_requirements_workarounds )
check "4.7: a missing file is not an error" 0 "$?"
[ ! -e "${local_requirements}" ]
check "4.7: and is not created either" 0 "$?"

#
# A release with no mkdocstrings pin at all is treated like a newer one.
#
printf 'Django==5.2.11\n' >"${requirements}"
printf 'mkdocstrings==1.0.7  # lab-packer workaround: netbox-community/netbox#23376\n' \
	>"${local_requirements}"
reconcile_requirements_workarounds
check "no upstream pin: the workaround is removed" 0 "$(tagged)"

echo
if [ "${failures}" -ne 0 ]; then
	echo "${failures} check(s) failed"
	exit 1
fi
echo "all checks passed"
