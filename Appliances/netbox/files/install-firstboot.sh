#!/bin/bash
# Install the first-boot bootstrap and wire the services to it, so a deployment
# that fails to bootstrap stays visibly down instead of serving a
# half-configured NetBox.
set -euo pipefail

echo '> Installing the first-boot bootstrap ...'
install -m 0700 -o root -g root \
	"${PAYLOAD_DIR}/netbox-firstboot.py" /usr/local/sbin/netbox-firstboot.py
python3 -m py_compile /usr/local/sbin/netbox-firstboot.py

install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/netbox-bootstrap.service" /etc/systemd/system/netbox-bootstrap.service
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/netbox-reconcile.service" /etc/systemd/system/netbox-reconcile.service

for unit in netbox netbox-rq nginx; do
	install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
	install -m 0644 -o root -g root \
		"${PAYLOAD_DIR}/systemd/netbox-requires.conf" \
		"/etc/systemd/system/${unit}.service.d/20-bootstrap.conf"
done

# Both units are pulled into multi-user.target, and cloud-final.service is
# ordered after multi-user.target. Ordering either of them after cloud-final
# closes a dependency cycle, and systemd breaks a cycle by deleting jobs: it
# dropped the bootstrap (so nothing that Requires= it started) and cloud-final
# itself (so cloud-init never finished and the deploy form stopped being
# applied), logging nothing against any unit. The appliance booted in thirteen
# seconds and served nothing. Fail the build rather than ship that again.
for unit in netbox-bootstrap netbox-reconcile; do
	if grep -qE '^(After|Requires|Wants)=.*cloud-(final|config)\.service' \
		"/etc/systemd/system/${unit}.service"; then
		echo "${unit}.service orders itself against a late cloud-init unit;" >&2
		echo 'that creates a dependency cycle through multi-user.target.' >&2
		exit 1
	fi
done

systemctl daemon-reload
systemctl enable netbox-bootstrap.service netbox-reconcile.service
echo '> First-boot bootstrap installed.'
