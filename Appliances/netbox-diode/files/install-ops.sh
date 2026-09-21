#!/bin/bash
# Day-two operations: the operator CLIs, the nightly backup timer, log
# rotation, the login summary, fail2ban and the host metrics exporter.
set -euo pipefail

echo '> Installing the operator CLIs ...'
for tool in diode-status diode-compose diode-agent diode-netbox diode-backup \
	diode-restore diode-upgrade diode-tls diode-credentials \
	diode-support-bundle diode-datadisk-grow; do
	install -m 0755 -o root -g root "${PAYLOAD_DIR}/bin/${tool}" "/usr/local/sbin/${tool}"
done
# /usr/local/sbin is on root's PATH but not on an unprivileged account's;
# these all need root anyway (diode-status excepted, and it drives the MOTD),
# so a symlink into /usr/local/bin would only produce confusing permission
# errors.

echo '> Installing the stack and backup units ...'
for unit in diode.service diode-backup.service diode-backup.timer \
	diode-datadisk.service; do
	install -m 0644 -o root -g root \
		"${PAYLOAD_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done
cat >/etc/default/diode-backup <<'DEFAULTS'
# Days of backups to keep in /srv/diode/backups. Note these live on the same
# disk as the data they protect: a convenience, not an off-box backup
# strategy.
RETENTION_DAYS=14
DEFAULTS
chmod 0644 /etc/default/diode-backup

echo '> Installing log rotation ...'
# Host-side logs only. Container logs are rotated by the Docker local log
# driver (max-size/max-file in daemon.json), because logrotate cannot safely
# truncate a file the runtime writes through its own logging driver.
install -m 0644 -o root -g root "${PAYLOAD_DIR}/logrotate/diode" /etc/logrotate.d/diode

echo '> Installing the login summary ...'
install -m 0755 -o root -g root "${PAYLOAD_DIR}/motd/99-diode" /etc/update-motd.d/99-diode

echo '> Configuring fail2ban ...'
install -m 0644 -o root -g root "${PAYLOAD_DIR}/fail2ban/diode.local" /etc/fail2ban/jail.d/diode.local
systemctl enable fail2ban.service
systemctl restart fail2ban.service
fail2ban-client status

echo '> Leaving the host metrics exporter off ...'
# Bound to loopback by the stock Ubuntu configuration and switched on only
# when the deploy form supplies an allowlist - the same rule the NetBox
# appliance follows. verify.sh asserts it is still disabled.
systemctl disable --now prometheus-node-exporter.service >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable diode.service diode-backup.timer diode-datadisk.service
echo '> Day-two operations installed.'
