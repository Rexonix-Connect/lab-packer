#!/bin/bash
# Prove the appliance actually works before it is allowed to become a
# template, then re-assert the hardened baseline and clean the guest.
#
# A NetBox that cannot serve its login page, or an image that lost a piece of
# the hardening it inherits, fails the build here rather than being discovered
# by whoever deploys it.
set -euo pipefail

STATE_DIR=/var/lib/netbox-appliance

echo '> Suppressing the first-boot bootstrap for the duration of the build ...'
# netbox.service, netbox-rq.service and nginx.service require
# netbox-bootstrap.service. The marker makes its condition fail, so systemd
# skips it and the dependency is satisfied without generating any of the
# per-deployment identity here. finalize.sh removes the marker again.
install -d -m 0755 "${STATE_DIR}"
echo 'build' >"${STATE_DIR}/bootstrapped"

echo '> Starting the appliance ...'
systemctl start postgresql redis-server netbox netbox-rq nginx

echo '> Waiting for NetBox to answer ...'
code=''
for _ in $(seq 1 60); do
	code="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/login/ || true)"
	[ "${code}" = '200' ] && break
	sleep 5
done
if [ "${code}" != '200' ]; then
	echo "> NetBox did not serve its login page (last HTTP status: ${code:-none})"
	systemctl --no-pager --full status netbox nginx || true
	journalctl --no-pager -u netbox -n 100 || true
	exit 1
fi
echo '> Login page served over HTTPS.'

echo '> Verifying the HTTP redirect ...'
redirect="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
if [ "${redirect}" != '301' ]; then
	echo "> plain HTTP returned ${redirect}, expected a 301 redirect"
	exit 1
fi

echo '> Verifying the API enforces authentication ...'
api="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/api/ || true)"
if [ "${api}" != '403' ]; then
	echo "> unauthenticated /api/ returned ${api}, expected 403"
	exit 1
fi

echo '> Verifying the installed NetBox version ...'
reported="$(netbox-manage shell -c 'from django.conf import settings; print(settings.VERSION)' | tail -n 1 | tr -d '[:space:]')"
expected="${NETBOX_VERSION#v}"
case "${reported}" in
"${expected}"*) echo "> NetBox ${reported}" ;;
*)
	echo "> NetBox reports ${reported}, expected ${expected}"
	exit 1
	;;
esac

echo '> Verifying the queue worker is processing jobs ...'
# netbox-rq also runs NetBox's built-in daily housekeeping job, which is why
# the appliance ships no housekeeping cron entry of its own.
systemctl is-active netbox-rq >/dev/null

echo '> Verifying the service hardening drop-ins are in effect ...'
for unit in netbox netbox-rq; do
	if [ "$(systemctl show "${unit}" -p NoNewPrivileges --value)" != 'yes' ]; then
		echo "> ${unit} is not running with NoNewPrivileges"
		exit 1
	fi
	if [ "$(systemctl show "${unit}" -p ProtectSystem --value)" != 'full' ]; then
		echo "> ${unit} is not running with ProtectSystem=full"
		exit 1
	fi
done

echo '> Verifying the data disk layout ...'
# The whole point of the separate disk is that NetBox growth cannot fill the
# 60 GB root, so assert every part of that actually landed on it.
findmnt --noheadings --mountpoint /srv/netbox
if [ "$(readlink -f /opt/netbox)" != '/srv/netbox' ]; then
	echo "> /opt/netbox resolves to $(readlink -f /opt/netbox), expected /srv/netbox"
	exit 1
fi
for path in /srv/netbox/venv/bin/python /srv/netbox/netbox/manage.py /srv/netbox/backups; do
	if [ ! -e "${path}" ]; then
		echo "> ${path} is missing; NetBox did not install onto the data disk"
		exit 1
	fi
done
pg_data="$(runuser -u postgres -- psql -tAc 'SHOW data_directory')"
case "${pg_data}" in
/srv/netbox/*) echo "> PostgreSQL data directory: ${pg_data}" ;;
*)
	echo "> PostgreSQL data directory is ${pg_data}, expected it under /srv/netbox"
	exit 1
	;;
esac
pg_encoding="$(runuser -u postgres -- psql -tAc "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='netbox'")"
if [ "${pg_encoding}" != 'UTF8' ]; then
	echo "> the netbox database is ${pg_encoding}, expected UTF8"
	exit 1
fi
# fstab must reference the filesystem by UUID: device names are not stable
# across clones, and a wrong entry would silently leave NetBox on the root disk.
if ! grep -qE '^UUID=[0-9a-fA-F-]+[[:space:]]+/srv/netbox[[:space:]]+ext4' /etc/fstab; then
	echo '> /etc/fstab has no UUID-based entry for /srv/netbox:'
	grep -n 'srv/netbox' /etc/fstab || true
	exit 1
fi
echo "> Data disk: $(findmnt -no SOURCE,SIZE,USED --mountpoint /srv/netbox)"

echo '> Verifying the firewall and enabled units ...'
ufw status | grep -qE '^80/tcp +ALLOW'
ufw status | grep -qE '^443/tcp +ALLOW'
for unit in netbox.service netbox-rq.service nginx.service postgresql.service \
	redis-server.service fail2ban.service netbox-bootstrap.service \
	netbox-reconcile.service netbox-backup.timer netbox-datadisk.service; do
	systemctl is-enabled "${unit}" >/dev/null
done
if systemctl is-enabled prometheus-node-exporter.service >/dev/null 2>&1; then
	echo '> prometheus-node-exporter is enabled; it must stay off until a deploy-time allowlist enables it'
	exit 1
fi

echo '> Re-verifying the hardened baseline ...'
# The same assertions Ubuntu/24/04-hardened makes, repeated after the whole
# NetBox stack was installed on top, so a package that relaxes a sysctl or
# unblocks a module cannot slip through.
for mod in algif_aead act_pedit esp4 esp6 rxrpc cramfs freevxfs jffs2 hfs hfsplus dccp sctp rds tipc; do
	if ! modprobe -n -v "${mod}" 2>/dev/null | grep -q '/bin/false'; then
		echo "> ${mod} is no longer blocked"
		exit 1
	fi
	if grep -qE "^${mod} " /proc/modules; then
		echo "> ${mod} is loaded; refusing to template a potentially vulnerable image"
		exit 1
	fi
done
for kv in kernel.dmesg_restrict=1 kernel.kptr_restrict=1 kernel.yama.ptrace_scope=1 kernel.unprivileged_bpf_disabled=2 net.core.bpf_jit_harden=2 fs.protected_fifos=2 fs.protected_regular=2 fs.suid_dumpable=0 kernel.io_uring_disabled=2 kernel.apparmor_restrict_unprivileged_userns=1; do
	key="${kv%%=*}"
	want="${kv##*=}"
	have="$(sysctl -n "${key}")"
	if [ "${have}" != "${want}" ]; then
		echo "> sysctl ${key} is ${have}, expected ${want}"
		exit 1
	fi
done
systemctl is-enabled auditd >/dev/null
id recovery >/dev/null
[ -x /usr/local/sbin/ovf-settings.py ]
systemctl is-enabled ovf-settings.service >/dev/null
lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'unavailable')"
case "${lockdown}" in
*'[integrity]'* | *'[confidentiality]'*) echo "> kernel lockdown active: ${lockdown}" ;;
*) echo "> WARNING: kernel lockdown not active (${lockdown}); is Secure Boot on?" ;;
esac

echo '> Stopping the appliance for templating ...'
systemctl stop netbox netbox-rq nginx fail2ban
# A clean PostgreSQL shutdown matters here: the migrated database ships inside
# the template, so it has to be consistent on disk.
systemctl stop postgresql
systemctl stop redis-server

echo '> Cleaning build logs and caches ...'
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /root/.cache /home/"${BUILD_USERNAME}"/.cache
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
for log in /var/log/audit/audit.log /var/log/wtmp /var/log/lastlog \
	/var/log/netbox/netbox.log /var/log/nginx/netbox-access.log \
	/var/log/nginx/netbox-error.log /var/log/nginx/access.log \
	/var/log/nginx/error.log; do
	if [ -f "${log}" ]; then
		: >"${log}"
	fi
done
find /var/log/postgresql -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
journalctl --rotate --quiet || true
journalctl --vacuum-time=1s --quiet || true

chmod 700 /tmp/packer-finalize-template.sh
echo '> Verification complete.'
