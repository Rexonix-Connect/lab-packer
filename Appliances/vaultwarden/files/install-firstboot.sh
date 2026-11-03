#!/bin/bash
# Install the first-boot bootstrap and wire the services to it, so a deployment
# that fails to bootstrap stays visibly down instead of serving half configured.
set -euo pipefail

echo '> Installing the first-boot bootstrap ...'
install -m 0700 -o root -g root \
	"${PAYLOAD_DIR}/vaultwarden-firstboot.py" /usr/local/sbin/vaultwarden-firstboot.py
python3 -m py_compile /usr/local/sbin/vaultwarden-firstboot.py

for unit in vaultwarden-bootstrap.service vaultwarden-reconcile.service; do
	install -m 0644 -o root -g root "${PAYLOAD_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
install -d -m 0755 /etc/systemd/system/nginx.service.d
install -m 0644 -o root -g root "${PAYLOAD_DIR}/systemd/nginx-requires.conf" \
	/etc/systemd/system/nginx.service.d/20-vaultwarden-bootstrap.conf

# The ordering-cycle trap the NetBox appliance once fell into: both units are
# pulled into multi-user.target, cloud-final.service is ordered after it, and
# an After= on a late cloud-init unit makes systemd silently delete jobs.
for unit in vaultwarden-bootstrap vaultwarden-reconcile; do
	if grep -qE '^After=.*cloud-(final|config)\.service' \
		"/etc/systemd/system/${unit}.service"; then
		echo "${unit}.service orders itself against a late cloud-init unit;" >&2
		echo 'that creates a dependency cycle through multi-user.target.' >&2
		exit 1
	fi
done

systemctl daemon-reload
systemctl enable vaultwarden-bootstrap.service vaultwarden-reconcile.service
echo '> First-boot bootstrap installed.'
