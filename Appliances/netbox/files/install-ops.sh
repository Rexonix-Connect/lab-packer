#!/bin/bash
# Day-two operations: the operator CLIs, the nightly backup timer, log
# rotation, the login summary, fail2ban and the host metrics exporter.
#
# NetBox's own housekeeping is deliberately absent here: since v4.4 it is a
# built-in daily system job executed by netbox-rq, so a cron entry or timer
# would run it a second time. `netbox-manage housekeeping` still runs it on
# demand.
set -euo pipefail

echo '> Installing the operator CLIs ...'
for tool in netbox-manage netbox-status netbox-credentials netbox-backup netbox-restore netbox-upgrade; do
	install -m 0755 -o root -g root "${PAYLOAD_DIR}/bin/${tool}" "/usr/local/sbin/${tool}"
done
# /usr/local/sbin is on root's PATH but not on an unprivileged account's; these
# all need root anyway, so a symlink into /usr/local/bin would only produce
# confusing permission errors.

echo '> Installing the backup timer ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/netbox-backup.service" /etc/systemd/system/netbox-backup.service
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/netbox-backup.timer" /etc/systemd/system/netbox-backup.timer
cat >/etc/default/netbox-backup <<'EOF'
# Days of backups to keep in /var/backups/netbox. Both the database dump and
# the file archive are pruned on the same schedule.
RETENTION_DAYS=14
EOF

echo '> Installing log rotation and the login summary ...'
install -m 0644 -o root -g root "${PAYLOAD_DIR}/logrotate/netbox" /etc/logrotate.d/netbox
install -m 0755 -o root -g root "${PAYLOAD_DIR}/motd/99-netbox" /etc/update-motd.d/99-netbox

echo '> Configuring fail2ban ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/fail2ban/netbox.local" /etc/fail2ban/jail.d/netbox.local
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/fail2ban/netbox-login.conf" /etc/fail2ban/filter.d/netbox-login.conf
# The jail reads nginx's access log, which does not exist until nginx has
# served a request; without the file fail2ban refuses to start the jail.
install -d -m 0755 -o root -g adm /var/log/nginx
: >>/var/log/nginx/netbox-access.log
chown www-data:adm /var/log/nginx/netbox-access.log
chmod 0640 /var/log/nginx/netbox-access.log
systemctl enable fail2ban.service

echo '> Pinning the node exporter to loopback ...'
# Only reachable through nginx's /node-metrics location, which is deny-all
# until the deploy form supplies an allowlist. The service itself stays
# disabled until then.
cat >/etc/default/prometheus-node-exporter <<'EOF'
# Bound to loopback: the appliance publishes host metrics through nginx's
# /node-metrics location, which enforces the deploy form's allowlist.
ARGS="--web.listen-address=127.0.0.1:9100"
EOF
systemctl disable --now prometheus-node-exporter.service

systemctl daemon-reload
systemctl enable netbox-backup.timer
echo '> Operations tooling installed.'
