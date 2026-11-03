#!/bin/bash
# Day-two operations: the operator CLIs, the guard, the nightly backup timer,
# the login summary and fail2ban.
set -euo pipefail

echo '> Installing the operator CLIs ...'
for tool in vaultwarden-status vaultwarden-guard vaultwarden-credentials \
	vaultwarden-admin-token vaultwarden-backup vaultwarden-restore \
	vaultwarden-upgrade vaultwarden-tls vaultwarden-datadisk-grow; do
	install -m 0755 -o root -g root "${PAYLOAD_DIR}/bin/${tool}" "/usr/local/sbin/${tool}"
	bash -n "/usr/local/sbin/${tool}"
done

echo '> Installing the backup timer ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/vaultwarden-backup.service" /etc/systemd/system/vaultwarden-backup.service
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/vaultwarden-backup.timer" /etc/systemd/system/vaultwarden-backup.timer
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/vaultwarden-backup.default" /etc/default/vaultwarden-backup

echo '> Installing the login summary ...'
install -m 0755 -o root -g root "${PAYLOAD_DIR}/motd/99-vaultwarden" /etc/update-motd.d/99-vaultwarden

echo '> Configuring fail2ban ...'
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/fail2ban/vaultwarden.local" /etc/fail2ban/jail.d/vaultwarden.local
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/fail2ban/vaultwarden.conf" /etc/fail2ban/filter.d/vaultwarden.conf
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/fail2ban/vaultwarden-admin.conf" /etc/fail2ban/filter.d/vaultwarden-admin.conf
# Prove the filters match the lines Vaultwarden actually writes, rather than
# discovering a dead jail after the first brute-force attempt.
check_filter() { # check_filter <filter> <sample line>
	if ! fail2ban-regex "${2}" "/etc/fail2ban/filter.d/${1}.conf" | grep -qE '^Lines: 1 lines, 0 ignored, 1 matched'; then
		echo "> fail2ban filter ${1} does not match: ${2}"
		fail2ban-regex "${2}" "/etc/fail2ban/filter.d/${1}.conf" || true
		exit 1
	fi
}
check_filter vaultwarden \
	'[2026-11-01 10:00:00.000][vaultwarden::api::identity][ERROR] Username or password is incorrect. Try again. IP: 192.0.2.10. Username: someone@example.com.'
check_filter vaultwarden-admin \
	'[2026-11-01 10:00:00.000][vaultwarden::api::admin][ERROR] Invalid admin token. IP: 192.0.2.10'
systemctl enable fail2ban.service

systemctl daemon-reload
systemctl enable vaultwarden-backup.timer
echo '> Operations tooling installed.'
