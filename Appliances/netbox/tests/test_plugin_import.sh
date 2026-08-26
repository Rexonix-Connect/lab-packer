#!/bin/bash
# Check how the appliance decides whether a plugin can be imported.
#
# NetBox is not a pip package: it lives in /opt/netbox/netbox and is importable
# only from there, and a plugin's __init__ imports netbox.plugins. A plain
# `python -c "import <module>"` therefore succeeds only for plugins that carry
# a fallback for NetBox being absent - and netbox-plugin used to use exactly
# that, so it installed netbox-attachments (which has one) and rejected
# netbox-inventory, netbox-secrets and netbox-custom-objects (which do not) as
# broken, on an appliance where all four were fine.
#
# Everything here runs against a stand-in tree in a temporary directory, via
# NETBOX_APPLIANCE_ROOT and NETBOX_APPLIANCE_CONFIG. No appliance, no NetBox,
# no Django, no root.
#
#     bash Appliances/netbox/tests/test_plugin_import.sh
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

#
# A stand-in for a deployed appliance.
#
root="${WORK}/srv/netbox"
packages="${WORK}/site-packages"
mkdir -p "${root}/netbox/netbox" "${root}/venv/bin" "${packages}"

# The NetBox project tree: importable only with ${root}/netbox as the working
# directory, which is the whole point.
: >"${root}/netbox/netbox/__init__.py"
: >"${root}/netbox/netbox/settings.py"
cat >"${root}/netbox/netbox/plugins.py" <<'EOF'
class PluginConfig:
    pass
EOF

# The venv python, seeing the stand-in site-packages.
cat >"${root}/venv/bin/python" <<EOF
#!/bin/sh
PYTHONPATH="${packages}\${PYTHONPATH:+:\$PYTHONPATH}" exec python3 "\$@"
EOF
chmod +x "${root}/venv/bin/python"

# Shaped like netbox-inventory: imports netbox.plugins with no fallback.
mkdir -p "${packages}/netbox_strict"
cat >"${packages}/netbox_strict/__init__.py" <<'EOF'
from netbox.plugins import PluginConfig

__version__ = "2.6.1"
EOF

# Shaped like netbox-attachments: tolerates NetBox being absent.
mkdir -p "${packages}/netbox_tolerant"
cat >"${packages}/netbox_tolerant/__init__.py" <<'EOF'
try:
    from netbox.plugins import PluginConfig
except ImportError:
    class PluginConfig:
        pass

__version__ = "11.2.3"
EOF

# Enough of Django for django.setup() to be called. The real thing loads the
# apps; here the question is only whether the import is attempted in the right
# place, which is what the bug was about.
mkdir -p "${packages}/django"
cat >"${packages}/django/__init__.py" <<'EOF'
def setup():
    pass
EOF

printf 'netbox-strict==2.6.1\nnetbox-tolerant==11.2.3\n' \
	>"${root}/local_requirements.txt"

config="${WORK}/appliance.json"
export NETBOX_APPLIANCE_ROOT="${root}"
export NETBOX_APPLIANCE_CONFIG="${config}"

#
# netbox-plugin list
#
printf '{"plugins": ["netbox_tolerant", "netbox_strict"]}\n' >"${config}"
output="$(bash "${BIN}/netbox-plugin" list 2>&1)"

grep -q 'netbox_strict .*importable (2.6.1)' <<<"${output}"
check "a plugin that imports netbox.plugins is importable" 0 "$?" "${output}"

grep -q 'netbox_tolerant .*importable (11.2.3)' <<<"${output}"
check "a plugin with its own fallback is importable too" 0 "$?" "${output}"

grep -q 'NOT IMPORTABLE' <<<"${output}"
check "neither is called broken" 1 "$?" "${output}"

# And the verdict still has to go the other way when a module really is absent.
printf '{"plugins": ["netbox_absent"]}\n' >"${config}"
output="$(bash "${BIN}/netbox-plugin" list 2>&1)"
grep -q 'netbox_absent .*NOT IMPORTABLE' <<<"${output}"
check "a module that is not installed is still reported" 0 "$?" "${output}"

#
# netbox-restore's pre-restore verification, which had the same probe: it
# refuses to touch the database when the backup's plugins cannot be imported.
#
probe="${WORK}/probe.py"
sed -n '/^python3 - /,/^PY$/p' "${BIN}/netbox-restore" | sed '1d;$d' >"${probe}"

printf '{"plugins": ["netbox_tolerant", "netbox_strict"]}\n' >"${config}"
output="$(cd "${WORK}" && python3 "${probe}" "${config}" "${root}" 2>&1)"
status="$?"
check "restore accepts plugins that are installed" 0 "${status}" "${output}"
grep -q '2 plugin(s) present' <<<"${output}"
check "restore says which plugins it found" 0 "$?" "${output}"

printf '{"plugins": ["netbox_strict", "netbox_absent"]}\n' >"${config}"
output="$(cd "${WORK}" && python3 "${probe}" "${config}" "${root}" 2>&1)"
status="$?"
check "restore refuses when a plugin is missing" 1 "${status}" "${output}"
grep -q 'netbox_absent' <<<"${output}"
check "restore names the missing plugin" 0 "$?" "${output}"
grep -q 'netbox_strict' <<<"${output}"
check "restore does not blame the plugin that is fine" 1 "$?" "${output}"

echo
if [ "${failures}" -eq 0 ]; then
	echo "ALL CHECKS PASSED"
	exit 0
fi
echo "${failures} FAILURE(S)"
exit 1
