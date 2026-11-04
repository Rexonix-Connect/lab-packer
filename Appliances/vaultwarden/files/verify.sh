#!/bin/bash
# Prove the appliance works before it is allowed to become a template, then
# re-assert the hardened baseline and the network exposure, and clean the
# guest of everything the proof created.
#
# "It works" means more than a 200: the web vault is served through nginx,
# registration is closed, the admin page is gated, nothing but SSH and the web
# ports is reachable from outside, a killed container comes back by itself,
# the guard refuses a foreign data disk, and a backup restores. Each of those
# is cheaper to find here than in a customer's vCenter.
set -euo pipefail

STATE_DIR=/var/lib/vaultwarden-appliance
CONFIG_DIR=/etc/vaultwarden
DATA_ROOT=/srv/vaultwarden

fail() {
	echo "> ${1}"
	echo '> --- diagnostics ---'
	systemctl --no-pager --full status vaultwarden nginx 'postgresql@*' 2>&1 | tail -n 80 || true
	journalctl --no-pager -u vaultwarden -n 100 || true
	journalctl --no-pager -u fail2ban -n 30 || true
	ss -ltnp || true
	tail -n 30 /var/log/nginx/vaultwarden-error.log /var/log/nginx/error.log 2>/dev/null || true
	exit 1
}

alive() { # alive <tries> - through nginx, the way a client reaches it
	local code=''
	for _ in $(seq 1 "${1}"); do
		code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/alive || true)"
		[ "${code}" = '200' ] && return 0
		sleep 5
	done
	echo "> last HTTP status from /alive: ${code:-none}"
	return 1
}

echo '> Suppressing the first-boot bootstrap for the duration of the build ...'
# vaultwarden.service and nginx.service require vaultwarden-bootstrap.service.
# The marker makes its condition fail, so systemd skips it and the dependency
# is satisfied without generating any per-deployment identity here.
install -d -m 0755 "${STATE_DIR}"
echo 'build' >"${STATE_DIR}/bootstrapped"

echo '> Creating a build-only identity ...'
# The real bootstrap's own functions, so the build exercises the code a
# deployment runs: the database, the volume id and the rendered settings.
python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location(
    'fb', '/usr/local/sbin/vaultwarden-firstboot.py')
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)
fb.ensure_volume()
fb.ensure_database()
fb.write_secret(fb.SECRET_ADMIN_TOKEN, fb.hash_admin_token('build-only'))
settings = fb.build_settings({}, 'localhost', fb.have_secret)
fb.write_file(fb.ENV_FILE, fb.render_env(settings), 0o600, 'root:root')
PY
grep -q "^ADMIN_TOKEN_FILE='/run/secrets/admin_token'$" "${CONFIG_DIR}/vaultwarden.env" ||
	fail 'the rendered settings do not point ADMIN_TOKEN_FILE at the secret'
if grep -qE '^(ADMIN_TOKEN|SMTP_PASSWORD|SSO_CLIENT_SECRET)=' "${CONFIG_DIR}/vaultwarden.env"; then
	fail 'a secret was rendered into the container environment'
fi

echo '> Starting the appliance ...'
systemctl start vaultwarden.service || fail 'vaultwarden.service did not start'
systemctl restart nginx.service
alive 60 || fail 'Vaultwarden did not answer /alive through nginx'
echo '> /alive answered through nginx.'

echo '> Verifying what is served ...'
# --version prints two lines, the server and the bundled web-vault; the first
# is the one pinned here.
reported="$(docker exec vaultwarden /vaultwarden --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
[ "${reported}" = "${VAULTWARDEN_VERSION}" ] ||
	fail "the container reports Vaultwarden ${reported:-?}, expected ${VAULTWARDEN_VERSION}"
echo "> Vaultwarden ${reported}"

vault="$(curl -sk --max-time 10 https://127.0.0.1/ || true)"
grep -qi '<html' <<<"${vault}" || fail 'the web vault was not served at /'

curl -sk --max-time 10 https://127.0.0.1/api/config | python3 -c 'import json, sys; json.load(sys.stdin)' ||
	fail '/api/config did not return JSON'

# A functional probe, not the /api/config flag: "disableUserRegistration" is
# false by design whenever invitations are on and mail is off (invited users
# must be able to reach the form), so the only honest check is that the
# server refuses an address nobody invited.
register="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' \
	-H 'Content-Type: application/json' \
	-d '{"email":"nobody@build.invalid","name":"probe"}' \
	https://127.0.0.1/identity/accounts/register/send-verification-email || true)"
[ "${register}" = '400' ] || fail "registration for an un-invited address answered ${register}, expected 400"
echo '> Registration refused for an un-invited address.'

redirect="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
[ "${redirect}" = '301' ] || fail "plain HTTP returned ${redirect}, expected 301"

# The admin page from an address other than loopback must be refused by nginx
# before Vaultwarden is asked, since no allowlist is deployed.
own_ip="$(ip -4 -o address show scope global | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
if [ -n "${own_ip}" ]; then
	admin="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://${own_ip}/admin" || true)"
	[ "${admin}" = '403' ] || fail "/admin from ${own_ip} returned ${admin}, expected 403 from nginx"
	echo "> /admin from ${own_ip}: 403"
fi
admin_page="$(curl -sk --max-time 10 -w '\n%{http_code}' https://127.0.0.1/admin || true)"
[ "${admin_page##*$'\n'}" = '200' ] || fail "/admin from loopback returned ${admin_page##*$'\n'}, expected the login page"
if grep -qi 'admin panel is disabled' <<<"${admin_page}"; then
	fail 'Vaultwarden reports the admin panel disabled: ADMIN_TOKEN_FILE was not read'
fi
# A 200 is the login page whether or not a token is configured; proving the
# token file is honoured means logging in with it.
admin_login="$(curl -sk --max-time 10 -o /dev/null -D - --data-urlencode 'token=build-only' https://127.0.0.1/admin || true)"
grep -qi '^set-cookie: VW_ADMIN=' <<<"${admin_login}" ||
	fail 'the admin token from ADMIN_TOKEN_FILE was not accepted by /admin'
echo '> Admin page: gated by address, token from the secret file accepted.'

echo '> Verifying the access log is redacted ...'
curl -sk --max-time 10 -o /dev/null 'https://127.0.0.1/alive?access_token=build-redaction-probe' || true
sleep 1
if grep -q 'build-redaction-probe' /var/log/nginx/vaultwarden-access.log; then
	fail 'a query string reached the nginx access log'
fi

echo '> Verifying network exposure ...'
# Every TCP listener not on loopback must be SSH or the two web ports.
unexpected="$(ss -H -ltn | awk '{print $4}' | while read -r local; do
	port="${local##*:}"
	addr="${local%:*}"
	case "${addr}" in 127.* | '[::1]') continue ;; esac
	case "${port}" in 22 | 80 | 443) ;; *) echo "${local}" ;; esac
done)"
[ -z "${unexpected}" ] || fail "unexpected listeners off loopback: ${unexpected}"
ss -H -ltn | awk '{print $4}' | grep -qx '127.0.0.1:8000' ||
	fail 'Vaultwarden is not bound to 127.0.0.1:8000'
if ss -H -ltn | awk '{print $4}' | grep -qE ':5432$'; then
	fail 'PostgreSQL has a TCP listener'
fi
if [ -n "$(docker ps --format '{{.Ports}}' | tr -d '[:space:]')" ]; then
	fail "a container publishes ports: $(docker ps --format '{{.Names}} {{.Ports}}')"
fi
[ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' vaultwarden)" = 'host' ] ||
	fail 'the vaultwarden container is not on the host network'
if iptables -S 2>/dev/null | grep -q DOCKER || nft list ruleset 2>/dev/null | grep -qi docker; then
	fail 'Docker has written netfilter rules'
fi
if docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden |
	grep -qE '^(ADMIN_TOKEN|SMTP_PASSWORD|SSO_CLIENT_SECRET)='; then
	fail 'a secret is visible in the container environment'
fi
[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' vaultwarden)" = 'true' ] ||
	fail 'the container root filesystem is writable'
[ "$(docker inspect --format '{{.Config.User}}' vaultwarden)" = "$(id -u vaultwarden):$(id -g vaultwarden)" ] ||
	fail 'the container does not run as the vaultwarden account'
echo '> Only 22, 80 and 443 are reachable; nothing is published by Docker.'

echo '> Verifying the database and data disk ...'
pg_data="$(runuser -u postgres -- psql -tAc 'SHOW data_directory')"
case "${pg_data}" in
"${DATA_ROOT}"/*) echo "> PostgreSQL data directory: ${pg_data}" ;;
*) fail "PostgreSQL data directory is ${pg_data}, expected it under ${DATA_ROOT}" ;;
esac
[ "$(runuser -u vaultwarden -- psql -X -tA -h /run/postgresql -d vaultwarden \
	-c "SELECT to_regclass('public.__diesel_schema_migrations') IS NOT NULL")" = 't' ] ||
	fail 'Vaultwarden did not create its schema in PostgreSQL'
[ -f "${DATA_ROOT}/data/rsa_key.pem" ] || fail 'no RSA signing key in the data directory'
[ -f "${STATE_DIR}/initialized" ] || fail 'the guard did not mark the deployment initialized'
grep -qE "^LABEL=vaultwarden-data[[:space:]]+${DATA_ROOT}[[:space:]]+ext4[[:space:]]+[^[:space:]]*noexec" /etc/fstab ||
	fail "/etc/fstab has no LABEL-based noexec entry for ${DATA_ROOT}"
# The mount point underneath must be immutable, so a missing disk can never
# be written to in its place.
umount_check="$(mktemp -d)"
mount --bind / "${umount_check}"
lsattr -d "${umount_check}${DATA_ROOT}" | grep -q -- '-i-' ||
	{ umount "${umount_check}"; fail "the ${DATA_ROOT} mount point on the root disk is not immutable"; }
umount "${umount_check}"
rmdir "${umount_check}"

echo '> Verifying the guard refuses a foreign data disk ...'
real_id="$(cat "${CONFIG_DIR}/volume-id")"
echo 'not-this-disk' >"${CONFIG_DIR}/volume-id"
if vaultwarden-guard pre-start >/dev/null 2>&1; then
	echo "${real_id}" >"${CONFIG_DIR}/volume-id"
	fail 'vaultwarden-guard accepted a data disk with the wrong volume id'
fi
echo "${real_id}" >"${CONFIG_DIR}/volume-id"
vaultwarden-guard pre-start >/dev/null || fail 'vaultwarden-guard refused the correct data disk'

echo '> Verifying a killed container is recovered ...'
docker kill vaultwarden >/dev/null
sleep 5
alive 30 || fail 'Vaultwarden did not come back after its container was killed'
echo '> Recovered.'

echo '> Verifying backup and restore ...'
vaultwarden-backup || fail 'vaultwarden-backup failed'
stamp="$(ls -1t "${DATA_ROOT}"/backups/vaultwarden-*.dump | head -n 1 | sed 's#.*/vaultwarden-##; s#\.dump$##')"
[ -n "${stamp}" ] || fail 'vaultwarden-backup wrote no dump'
[ -f "${DATA_ROOT}/backups/vaultwarden-${stamp}.files.tar.gz" ] || fail 'vaultwarden-backup wrote no file archive'
[ "$(stat -c %a "${DATA_ROOT}/backups/vaultwarden-${stamp}.dump")" = '600' ] || fail 'the dump is not 0600'
alive 12 || fail 'Vaultwarden did not come back after the backup'
key_before="$(sha256sum "${DATA_ROOT}/data/rsa_key.pem" | awk '{print $1}')"
vaultwarden-restore "${stamp}" --yes || fail 'vaultwarden-restore failed'
alive 30 || fail 'Vaultwarden did not come back after the restore'
[ "$(sha256sum "${DATA_ROOT}/data/rsa_key.pem" | awk '{print $1}')" = "${key_before}" ] ||
	fail 'the restore did not bring back the same RSA signing key'
echo '> Backup and restore round-trip passed.'

echo '> Verifying the firewall and enabled units ...'
# The allowlists are ufw rules; with ufw inactive they are silently inert.
ufw status | grep -q '^Status: active' || fail 'ufw is not active'
for unit in vaultwarden.service nginx.service docker.service fail2ban.service \
	vaultwarden-bootstrap.service vaultwarden-reconcile.service \
	vaultwarden-backup.timer vaultwarden-datadisk.service; do
	systemctl is-enabled "${unit}" >/dev/null || fail "${unit} is not enabled"
done
# The directory sync ships installed but off: there is nothing to sync until
# an organization exists on a deployed appliance. The service has no
# [Install] section (static); the timer must not be enabled; the command
# must know it is unconfigured and refuse to run.
[ "$(systemctl is-enabled vaultwarden-dirsync.service 2>/dev/null || true)" = 'static' ] ||
	fail 'vaultwarden-dirsync.service is missing or not static'
[ "$(systemctl is-enabled vaultwarden-dirsync.timer 2>/dev/null || true)" = 'disabled' ] ||
	fail 'vaultwarden-dirsync.timer must ship disabled'
[ "$(cat /opt/bitwarden-directory-connector/VERSION 2>/dev/null)" = "${DIRECTORY_CONNECTOR_VERSION}" ] ||
	fail "the shipped Directory Connector is not ${DIRECTORY_CONNECTOR_VERSION}"
# Captured first: under pipefail, `status | grep -q` fails whenever grep
# exits before status has written its second line (SIGPIPE), which it
# often does.
dirsync_status="$(vaultwarden-dirsync status)"
grep -q 'not configured' <<<"${dirsync_status}" ||
	fail "vaultwarden-dirsync status does not report the sync as unconfigured: ${dirsync_status}"
if runuser -u vaultwarden-dirsync -- /usr/local/sbin/vaultwarden-dirsync run >/dev/null 2>&1; then
	fail 'vaultwarden-dirsync run must refuse without a configuration'
fi
echo "> Directory Connector ${DIRECTORY_CONNECTOR_VERSION}: installed, disabled, refuses to run unconfigured."

echo '> Verifying bwdc runs inside the sync unit sandbox ...'
# A throwaway configuration pointing at a port nothing listens on, so the
# unit gets exactly as far as bwdc failing to log in. That proves the Node
# binary starts and runs under the unit's syscall filter and address-family
# restrictions: a sandbox that kills it would end the unit by signal here,
# on the build, instead of at a customer's first sync.
DIRSYNC_ROOT=/var/lib/vaultwarden-dirsync
runuser -u vaultwarden-dirsync -- env HOME="${DIRSYNC_ROOT}" \
	BITWARDENCLI_CONNECTOR_APPDATA_DIR="${DIRSYNC_ROOT}/appdata" \
	BITWARDENCLI_CONNECTOR_PLAINTEXT_SECRETS=true \
	/opt/bitwarden-directory-connector/bwdc --quiet --nointeraction config server https://127.0.0.1:9 ||
	fail 'bwdc could not write its throwaway configuration'
printf 'BW_CLIENTID=organization.00000000-0000-0000-0000-000000000000\nBW_CLIENTSECRET=build-only\n' \
	>"${DIRSYNC_ROOT}/credentials.env"
chown vaultwarden-dirsync:vaultwarden-dirsync "${DIRSYNC_ROOT}/credentials.env"
chmod 0600 "${DIRSYNC_ROOT}/credentials.env"
if systemctl start vaultwarden-dirsync.service >/dev/null 2>&1; then
	fail 'the sync unit succeeded against a port nothing listens on'
fi
result="$(systemctl show vaultwarden-dirsync.service -p Result --value)"
if [ "${result}" != 'exit-code' ]; then
	journalctl --no-pager -u vaultwarden-dirsync -n 40 || true
	fail "the sync unit ended with Result=${result}; a signal means the sandbox killed bwdc"
fi
# Result=exit-code is the wrapper's exit, not bwdc's: the wrapper exits 1
# whether bwdc answered or was killed underneath it. So the journal must
# hold a login failure that carries bwdc's own response - a sandbox that
# kills Node leaves "killed by signal", and a bwdc that printed nothing
# leaves "no output", and both fail the build.
dirsync_journal="$(journalctl --no-pager -u vaultwarden-dirsync -b)"
login_line="$(grep 'login failed:' <<<"${dirsync_journal}" | tail -n 1 || true)"
[ -n "${login_line}" ] || {
	echo "${dirsync_journal}" | tail -n 40
	fail 'the sync unit did not get as far as a login attempt'
}
case "${login_line}" in
*'killed by signal'* | *'no output'*)
	echo "${dirsync_journal}" | tail -n 40
	fail "bwdc did not answer under the unit sandbox: ${login_line}"
	;;
esac
echo "> bwdc answered under the sandbox: ${login_line#*login failed: }"
systemctl reset-failed vaultwarden-dirsync.service || true
rm -rf "${DIRSYNC_ROOT}/appdata" "${DIRSYNC_ROOT}/credentials.env" "${DIRSYNC_ROOT}/state.json"
install -d -m 0700 -o vaultwarden-dirsync -g vaultwarden-dirsync "${DIRSYNC_ROOT}/appdata"
echo '> bwdc ran under the unit sandbox and reported the failure itself, as it should with no server.'
systemctl is-active fail2ban.service >/dev/null || systemctl start fail2ban.service
# Jails come up asynchronously after the service is active.
for jail in vaultwarden vaultwarden-admin; do
	for _ in $(seq 1 30); do
		fail2ban-client status "${jail}" >/dev/null 2>&1 && break
		sleep 1
	done
	if ! fail2ban-client status "${jail}" >/dev/null 2>&1; then
		journalctl --no-pager -u fail2ban -n 50 || true
		fail2ban-client status || true
		fail "the ${jail} fail2ban jail is not running"
	fi
done
if journalctl -b --no-pager | grep -iE 'ordering cycle|deleted to break'; then
	fail 'systemd reported an ordering cycle'
fi

echo '> Re-verifying the hardened baseline ...'
# The same assertions Ubuntu/24/04-hardened makes, repeated after Docker,
# PostgreSQL and nginx were installed on top.
for mod in algif_aead act_pedit esp4 esp6 rxrpc cramfs freevxfs jffs2 hfs hfsplus dccp sctp rds tipc; do
	if ! modprobe -n -v "${mod}" 2>/dev/null | grep -q '/bin/false'; then
		fail "${mod} is no longer blocked"
	fi
	if grep -qE "^${mod} " /proc/modules; then
		fail "${mod} is loaded; refusing to template a potentially vulnerable image"
	fi
done
for kv in kernel.dmesg_restrict=1 kernel.kptr_restrict=1 kernel.yama.ptrace_scope=1 kernel.unprivileged_bpf_disabled=2 net.core.bpf_jit_harden=2 fs.protected_fifos=2 fs.protected_regular=2 fs.suid_dumpable=0 kernel.io_uring_disabled=2 kernel.apparmor_restrict_unprivileged_userns=1; do
	key="${kv%%=*}"
	want="${kv##*=}"
	have="$(sysctl -n "${key}")"
	[ "${have}" = "${want}" ] || fail "sysctl ${key} is ${have}, expected ${want}"
done
# Docker would normally switch on forwarding for its bridge. With bridge=none
# and iptables=false it must not have.
[ "$(sysctl -n net.ipv4.ip_forward)" = '0' ] || fail 'net.ipv4.ip_forward was turned on'
systemctl is-enabled auditd >/dev/null || fail 'auditd is not enabled'
id recovery >/dev/null || fail 'the recovery account is missing'
[ -x /usr/local/sbin/ovf-settings.py ] || fail 'ovf-settings.py is missing'
systemctl is-enabled ovf-settings.service >/dev/null || fail 'ovf-settings.service is not enabled'
lockdown="$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'unavailable')"
case "${lockdown}" in
*'[integrity]'* | *'[confidentiality]'*) echo "> kernel lockdown active: ${lockdown}" ;;
*) echo "> WARNING: kernel lockdown not active (${lockdown}); is Secure Boot on?" ;;
esac

echo '> Stopping the appliance and removing everything the proof created ...'
systemctl stop vaultwarden.service nginx.service fail2ban.service
docker compose --project-directory "${CONFIG_DIR}" down --timeout 30 >/dev/null 2>&1 || true
# The template must carry no schema, no signing key and no admin token. The
# bootstrap creates all three afresh on every deployment.
runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 \
	-c 'DROP DATABASE IF EXISTS vaultwarden' -c 'DROP ROLE IF EXISTS vaultwarden'
find "${DATA_ROOT}/data" -mindepth 1 -delete
find "${DATA_ROOT}/backups" -mindepth 1 -delete
rm -f "${DATA_ROOT}/.volume-id"
systemctl stop 'postgresql@*'
# A clean shutdown, so the cluster the template ships is consistent on disk.

echo '> Cleaning build logs and caches ...'
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /root/.cache /home/"${BUILD_USERNAME}"/.cache
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
for log in /var/log/audit/audit.log /var/log/wtmp /var/log/lastlog \
	/var/log/nginx/vaultwarden-access.log /var/log/nginx/vaultwarden-error.log \
	/var/log/nginx/access.log /var/log/nginx/error.log; do
	if [ -f "${log}" ]; then
		: >"${log}"
	fi
done
find /var/log/postgresql -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
journalctl --rotate --quiet || true
journalctl --vacuum-time=1s --quiet || true

chmod 700 /tmp/packer-finalize-template.sh
echo '> Verification complete.'
