#!/bin/bash
# Prove the appliance actually works before it is allowed to become a
# template, then re-assert the hardened baseline and clean the guest.
#
# A stack that does not come up, or an image that lost a piece of the
# hardening it inherits, fails the build here rather than being discovered by
# whoever deploys it.
set -euo pipefail

STATE_DIR=/var/lib/diode-appliance
CONFIG_DIR=/etc/diode
PROJECT_DIR="${CONFIG_DIR}/compose"

echo '> Suppressing the first-boot bootstrap for the duration of the build ...'
# diode.service and nginx.service require diode-bootstrap.service. The marker
# makes its condition fail, so systemd skips it and the dependency is
# satisfied without generating any per-deployment identity here.
# install-diode.sh already rendered a throwaway .env for the build, and
# finalize.sh removes the marker, the .env and the volumes again.
install -d -m 0755 "${STATE_DIR}"
echo 'build' >"${STATE_DIR}/bootstrapped"

echo '> Starting the Diode stack ...'
systemctl start diode.service
# restart, not start: nginx is already running from the package installation,
# and `systemctl start` on an active unit is a no-op that would leave it
# serving whatever configuration it was launched with.
systemctl restart nginx

echo '> Waiting for every container to be running ...'
running=0
for _ in $(seq 1 60); do
	state="$(docker compose --project-directory "${PROJECT_DIR}" ps --format json 2>/dev/null || true)"
	if [ -n "${state}" ]; then
		total="$(printf '%s' "${state}" | jq -s 'length')"
		up="$(printf '%s' "${state}" | jq -s '[.[] | select(.State == "running")] | length')"
		# hydra-migrate and diode-auth-bootstrap are one-shot: they do their
		# work and exit, so "every long-running service is up" is the real
		# question, not "nothing has exited".
		if [ "${up}" -ge 7 ]; then
			running=1
			echo "> ${up}/${total} containers running"
			break
		fi
	fi
	sleep 5
done
if [ "${running}" -ne 1 ]; then
	echo '> the Diode stack did not come up'
	docker compose --project-directory "${PROJECT_DIR}" ps || true
	docker compose --project-directory "${PROJECT_DIR}" logs --tail 50 || true
	exit 1
fi

echo '> Verifying the ingress answers through host nginx ...'
code=''
for _ in $(seq 1 30); do
	# Any HTTP answer proves the whole path works: TLS on 443, host nginx,
	# the loopback hop, and the ingress container's own routing. The auth
	# endpoint rejects this request, and a rejection is an answer.
	code="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/diode/auth/ || true)"
	case "${code}" in
	2* | 3* | 4*) break ;;
	esac
	code=''
	sleep 5
done
if [ -z "${code}" ]; then
	echo '> the ingress did not answer through nginx'
	echo "> Direct to the ingress container (127.0.0.1:8080): $(curl -s --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/diode/auth/ || true)"
	ss -ltnp || true
	tail -n 50 /var/log/nginx/diode-error.log /var/log/nginx/error.log 2>/dev/null || true
	docker compose --project-directory "${PROJECT_DIR}" logs --tail 50 ingress-nginx || true
	exit 1
fi
echo "> Ingress answered with HTTP ${code}."

echo '> Verifying the HTTP redirect ...'
redirect="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || true)"
if [ "${redirect}" != '301' ]; then
	echo "> plain HTTP returned ${redirect}, expected a 301 redirect"
	exit 1
fi

echo '> Verifying nothing is published outside loopback ...'
# This is the assertion the whole networking design rests on. Docker inserts
# its rules ahead of ufw's chains, so a container published on 0.0.0.0 would
# be reachable whatever ufw says, and nothing else in this image would notice.
offenders="$(ss -H -ltn | awk '{print $4}' |
	grep -vE '^(127\.0\.0\.1|\[::1\]|127\.0\.0\.53)' |
	grep -vE ':(22|80|443)$' || true)"
if [ -n "${offenders}" ]; then
	echo '> something is listening on a non-loopback address other than 22/80/443:'
	printf '%s\n' "${offenders}"
	ss -ltnp || true
	exit 1
fi
echo '> Only SSH and the web ports are reachable from the network.'

echo '> Verifying the image pins ...'
if grep -qE ':latest$|:-latest' "${CONFIG_DIR}/env.template" "${PROJECT_DIR}/docker-compose.yaml"; then
	echo '> an image tag resolves to "latest"; an appliance must pin what it runs'
	grep -nE ':latest$|:-latest' "${CONFIG_DIR}/env.template" "${PROJECT_DIR}/docker-compose.yaml"
	exit 1
fi
if [ ! -s "${CONFIG_DIR}/images.lock" ]; then
	echo '> /etc/diode/images.lock is missing or empty'
	exit 1
fi
if grep -q '<none>' "${CONFIG_DIR}/images.lock"; then
	echo '> an image has no repository digest recorded:'
	grep -n '<none>' "${CONFIG_DIR}/images.lock"
	exit 1
fi
echo "> $(grep -vc '^#' "${CONFIG_DIR}/images.lock") images pinned by digest."

echo '> Verifying the discovery agent is present but off ...'
docker image inspect "netboxlabs/orb-agent:${AGENT_VERSION}" >/dev/null
if systemctl is-enabled diode-agent.service >/dev/null 2>&1; then
	echo '> diode-agent.service is enabled; it must stay off until the deploy form asks for it'
	exit 1
fi
if [ -e "${CONFIG_DIR}/agent/agent.yaml" ]; then
	echo '> a rendered agent.yaml exists in the image; only first boot may create one'
	exit 1
fi

echo '> Verifying the data disk layout ...'
findmnt --noheadings --mountpoint /srv/diode
actual_root="$(docker info --format '{{.DockerRootDir}}')"
if [ "${actual_root}" != '/srv/diode/docker' ]; then
	echo "> Docker root is ${actual_root}, expected /srv/diode/docker"
	exit 1
fi
for path in /srv/diode/docker /srv/diode/backups; do
	if [ ! -d "${path}" ]; then
		echo "> ${path} is missing"
		exit 1
	fi
done
# fstab must reference the filesystem by UUID: device names are not stable
# across clones, and a wrong entry would silently leave Docker on the root disk.
if ! grep -qE '^UUID=[0-9a-fA-F-]+[[:space:]]+/srv/diode[[:space:]]+ext4' /etc/fstab; then
	echo '> /etc/fstab has no UUID-based entry for /srv/diode:'
	grep -n 'srv/diode' /etc/fstab || true
	exit 1
fi
echo "> Data disk: $(findmnt -no SOURCE,SIZE,USED --mountpoint /srv/diode)"

echo '> Verifying the firewall and enabled units ...'
ufw status | grep -qE '^80/tcp +ALLOW'
ufw status | grep -qE '^443/tcp +ALLOW'
for unit in docker.service nginx.service fail2ban.service diode.service \
	diode-bootstrap.service diode-reconcile.service diode-backup.timer \
	diode-datadisk.service; do
	systemctl is-enabled "${unit}" >/dev/null
done
if systemctl is-enabled prometheus-node-exporter.service >/dev/null 2>&1; then
	echo '> prometheus-node-exporter is enabled; it must stay off until a deploy-time allowlist enables it'
	exit 1
fi

echo '> Re-verifying the hardened baseline ...'
# The same assertions Ubuntu/24/04-hardened makes, repeated after Docker and
# the whole Diode stack were installed on top, so a package that relaxes a
# sysctl or unblocks a module cannot slip through.
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
# down --volumes, not stop: the volumes hold databases initialized with the
# build's throwaway passwords. They must not ship - first boot has to create
# them again with the secrets it generates. This is the single most important
# line in the file.
docker compose --project-directory "${PROJECT_DIR}" down --volumes --timeout 60
systemctl stop nginx fail2ban
systemctl stop docker.service docker.socket

echo '> Cleaning build logs and caches ...'
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /root/.cache /home/"${BUILD_USERNAME}"/.cache
find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -delete
for log in /var/log/audit/audit.log /var/log/wtmp /var/log/lastlog \
	/var/log/nginx/diode-access.log /var/log/nginx/diode-error.log \
	/var/log/nginx/access.log /var/log/nginx/error.log; do
	if [ -f "${log}" ]; then
		: >"${log}"
	fi
done
journalctl --rotate --quiet || true
journalctl --vacuum-time=1s --quiet || true

chmod 700 /tmp/packer-finalize-template.sh
echo '> Verification complete.'
