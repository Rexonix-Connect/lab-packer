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

systemctl daemon-reload
systemctl enable netbox-bootstrap.service netbox-reconcile.service
echo '> First-boot bootstrap installed.'
