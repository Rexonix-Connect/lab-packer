#!/bin/bash
# The optional NetBox Discovery agent (orb-agent), baked in but switched OFF.
#
# The agent belongs near the devices it discovers, which for a multi-site
# customer is not this VM. It is here for the single-site case - a lab, a demo,
# one campus - where standing up a second host to run one container is not
# worth it. agent.enabled on the deploy form turns it on; nothing starts
# otherwise, and an appliance deployed as a pure ingestion server carries the
# image and never runs it.
#
# Two things about how it runs, both deliberate:
#
#   --net=host, because network discovery is nmap: it needs raw sockets for
#   SYN scans and ICMP host discovery, and the agent's own documentation says
#   host networking is how you get them on Linux. It also means the agent
#   publishes nothing, so the loopback-only rule the rest of this appliance
#   follows is not weakened by it.
#
#   Device credentials are NOT on the deploy form. SNMP communities and SSH
#   keys for a customer's whole estate are worth far more than one admin
#   password, and a vApp property is stored in the VM configuration in
#   cleartext, readable by any vCenter user who can see the VM - which the
#   deploy form says of its own password fields. They go in afterwards with
#   `diode-agent credentials`, into a 0600 file.
set -euo pipefail

CONFIG_DIR=/etc/diode
AGENT_DIR="${CONFIG_DIR}/agent"

echo '> Installing the discovery agent configuration ...'
install -d -m 0750 -o root -g root "${AGENT_DIR}"
install -d -m 0750 -o root -g root "${AGENT_DIR}/policies.d"
install -m 0640 -o root -g root \
	"${PAYLOAD_DIR}/agent/agent.yaml.template" "${AGENT_DIR}/agent.yaml.template"
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/agent/policies.d/README" "${AGENT_DIR}/policies.d/README"

echo "> Pinning the agent image to ${AGENT_VERSION} ..."
cat >"${AGENT_DIR}/image.env" <<IMAGE
# Written at build time. diode-agent rewrites it when the agent is upgraded.
ORB_AGENT_IMAGE=netboxlabs/orb-agent:${AGENT_VERSION}
IMAGE
chmod 0644 "${AGENT_DIR}/image.env"

echo '> Baking the agent image into the template ...'
docker pull "netboxlabs/orb-agent:${AGENT_VERSION}"
docker image inspect "netboxlabs/orb-agent:${AGENT_VERSION}" >/dev/null

echo '> Installing the agent unit (disabled) ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/diode-agent.service" /etc/systemd/system/diode-agent.service
systemctl daemon-reload
# Deliberately not enabled: diode-firstboot.py enables it only when
# agent.enabled is set on the deploy form. verify.sh asserts it stays off.
systemctl disable diode-agent.service >/dev/null 2>&1 || true

echo '> Discovery agent installed (off until the deploy form enables it).'
