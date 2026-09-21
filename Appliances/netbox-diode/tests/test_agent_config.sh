#!/bin/bash
# Check the discovery agent's shipped configuration, and the promises the
# appliance makes about it.
#
# Two of these are security properties rather than correctness ones, and both
# are the kind that quietly stop being true during a refactor:
#
#   - No device credential is ever collected on the deploy form. A vApp
#     property is stored in the VM configuration in cleartext and is readable
#     by any vCenter user who can see the VM. One admin password is an
#     acceptable risk there; SNMP communities and SSH keys for a customer's
#     whole estate are not.
#   - The default policy is a ping scan, not the port sweep a bare target list
#     gives you. `nmap <targets>` means -sS -p1-1000 against every host, which
#     on a production network is both slow and conspicuous.
#
#     bash Appliances/netbox-diode/tests/test_agent_config.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLIANCE="${HERE}/../files/diode-appliance"
TEMPLATE="${APPLIANCE}/agent/agent.yaml.template"
UNIT="${APPLIANCE}/systemd/diode-agent.service"
DESCRIPTORS="${HERE}/../../../shared/vapp-descriptors/netbox-diode.json"

failures=0
check() { # check <label> <condition-exit> [detail]
	if [ "${2}" -eq 0 ]; then
		printf 'ok   %s\n' "${1}"
	else
		printf 'FAIL %s%s\n' "${1}" "${3:+ -- $3}"
		failures=$((failures + 1))
	fi
}

# --- the template renders to valid YAML --------------------------------
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
sed -e 's/__AGENT_NAME__/diode-appliance/' "${TEMPLATE}" |
	awk '{ if ($0 ~ /__AGENT_TARGETS__/) print "            - 192.0.2.0/24"; else print }' \
		>"${rendered}"
python3 - "${rendered}" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("skip agent.yaml parse: PyYAML not available")
    sys.exit(0)
with open(sys.argv[1]) as handle:
    config = yaml.safe_load(handle)
policy = config["orb"]["policies"]["network_discovery"]["appliance_default"]
assert policy["scope"]["targets"] == ["192.0.2.0/24"], policy["scope"]
assert policy["scope"].get("ping_scan") is True, "default policy must ping scan"
common = config["orb"]["backends"]["common"]["diode"]
assert common["target"].startswith("grpc://127.0.0.1:"), common["target"]
assert common["client_id"] == "${DIODE_CLIENT_ID}", common["client_id"]
assert common["client_secret"] == "${DIODE_CLIENT_SECRET}", common
print("ok   rendered agent.yaml parses and keeps its defaults")
PY
check "rendered agent.yaml is valid" "$?"

# --- no credential is embedded in the template -------------------------
embedded="$(grep -nE '(password|secret|community):\s*[^$[:space:]]' "${TEMPLATE}" || true)"
check "no literal credential in agent.yaml.template" \
	"$([ -z "${embedded}" ] && echo 0 || echo 1)" "${embedded}"

# --- no credential is collected on the deploy form ---------------------
form_secrets="$(python3 - "${DESCRIPTORS}" <<'PY'
import json, sys, re
with open(sys.argv[1]) as handle:
    descriptors = json.load(handle)["descriptors"]
bad = [d["id"] for d in descriptors
       if d["type"] == "password"
       or re.search(r"password|secret|community|credential|ssh-key",
                    d["id"], re.I)]
print(" ".join(bad))
PY
)"
check "the deploy form collects no device credential" \
	"$([ -z "${form_secrets}" ] && echo 0 || echo 1)" "${form_secrets}"

# --- the agent is host-networked and publishes nothing -----------------
check "the agent unit uses host networking (raw sockets for nmap)" \
	"$(grep -q -- '--net=host' "${UNIT}" && echo 0 || echo 1)"
published="$(grep -nE '^\s+-p |--publish' "${UNIT}" || true)"
check "the agent unit publishes no port" \
	"$([ -z "${published}" ] && echo 0 || echo 1)" "${published}"

# --- the agent stays off unless asked for -------------------------------
check "the agent unit is conditional on a rendered agent.yaml" \
	"$(grep -q '^ConditionPathExists=/etc/diode/agent/agent.yaml' "${UNIT}" && echo 0 || echo 1)"
check "install-agent.sh does not enable the unit" \
	"$(grep -q 'systemctl disable diode-agent.service' "${APPLIANCE}/../install-agent.sh" && echo 0 || echo 1)"

echo
if [ "${failures}" -eq 0 ]; then
	echo "PASS"
else
	echo "FAIL (${failures})"
fi
exit "$((failures == 0 ? 0 : 1))"
