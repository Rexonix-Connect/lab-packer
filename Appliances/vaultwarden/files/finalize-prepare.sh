#!/bin/bash
# Everything the template must not carry that can be removed while the Packer
# SSH session is still in use - so it runs as an ordinary provisioner, whose
# output Packer shows. The remaining steps, which end the session (the build
# account, the host keys, the machine id, the power-off), are in finalize.sh,
# the shutdown command, whose output Packer never shows.
#
# verify.sh has already dropped the database, emptied the data disk and
# stopped the services; this asserts that, then removes everything generated
# during the build. Every one of these is recreated per deployment by
# vaultwarden-firstboot.py.
set -euo pipefail

echo '> Stopping the appliance services ...'
systemctl stop vaultwarden.service nginx.service fail2ban.service || true
systemctl stop 'postgresql@*' || true

echo '> Asserting the data disk carries no instance ...'
leftover="$(find /srv/vaultwarden/data /srv/vaultwarden/backups -mindepth 1 -print 2>/dev/null | head -n 20 || true)"
if [ -n "${leftover}" ]; then
	echo '> /srv/vaultwarden still holds data or backups; refusing to export the template:' >&2
	echo "${leftover}" >&2
	exit 1
fi
rm -f /srv/vaultwarden/.volume-id

echo '> Removing the build-time configuration, secrets and TLS material ...'
rm -f /etc/vaultwarden/vaultwarden.env /etc/vaultwarden/volume-id
find /etc/vaultwarden/secrets -mindepth 1 -delete
rm -f /etc/vaultwarden/tls/vaultwarden.crt /etc/vaultwarden/tls/vaultwarden.key \
	/etc/vaultwarden/tls/.self-signed
rm -rf /var/lib/vaultwarden-appliance
rm -f /root/vaultwarden-credentials.txt /etc/issue.d/60-vaultwarden.issue
rm -f /etc/apt/apt.conf.d/95vaultwarden-proxy /etc/systemd/system/docker.service.d/30-proxy.conf

echo '> Asserting the directory sync is unconfigured and clearing its state ...'
# Nothing configures it during the build; this makes sure, and leaves the
# sync account with an empty state directory, its timer disabled.
if [ -f /var/lib/vaultwarden-dirsync/credentials.env ]; then
	echo '> the directory sync was configured during the build; refusing to export the template' >&2
	exit 1
fi
systemctl disable --now vaultwarden-dirsync.timer >/dev/null 2>&1 || true
rm -rf /var/lib/vaultwarden-dirsync/appdata /var/lib/vaultwarden-dirsync/state.json \
	/etc/systemd/system/vaultwarden-dirsync.timer.d /etc/systemd/system/vaultwarden-dirsync.service.d
install -d -m 0700 -o vaultwarden-dirsync -g vaultwarden-dirsync /var/lib/vaultwarden-dirsync/appdata
systemctl daemon-reload

echo '> Removing appliance-owned firewall rules ...'
# The first-boot bootstrap owns these (comment vaultwarden-https/-ssh) and
# creates them from the deploy form. The build's restore test runs a
# reconcile, which adds some; the template ships with the base SSH rule only.
echo '> ufw rules before:'
ufw status numbered || true
numbers="$(ufw status numbered 2>/dev/null |
	sed -nE 's/^\[ *([0-9]+)\].*# *vaultwarden-(https|ssh)[[:space:]]*$/\1/p' |
	sort -rn || true)"
for number in ${numbers}; do
	ufw --force delete "${number}"
done
ufw allow ssh
if ufw status | grep -q 'vaultwarden-'; then
	echo '> appliance firewall rules survived; refusing to export the template' >&2
	ufw status numbered >&2 || true
	exit 1
fi

echo '> Resetting the deploy-time nginx snippets ...'
printf '# Written by vaultwarden-firstboot.py.\nserver_name _;\n' \
	>/etc/nginx/snippets/vaultwarden-server-name.conf
printf '# Written by vaultwarden-firstboot.py.\nallow 127.0.0.1;\nallow ::1;\ndeny all;\n' \
	>/etc/nginx/snippets/vaultwarden-admin.conf
printf '# Written by vaultwarden-firstboot.py.\n' \
	>/etc/nginx/snippets/vaultwarden-hsts.conf

echo '> Removing stopped containers (the image itself ships) ...'
docker container prune --force >/dev/null 2>&1 || true

# Inherited from older base images, as on the NetBox appliance: a vagrant
# account and SSH password authentication. The appliance clones an already
# built base, so it purges both itself rather than wait for a rebuild.
echo '> Purging inherited build credentials ...'
rm -f /home/vagrant/.ssh/authorized_keys /etc/sudoers.d/vagrant
if id vagrant >/dev/null 2>&1; then
	userdel -r vagrant 2>/dev/null || userdel -f -r vagrant 2>/dev/null || true
	rm -rf /home/vagrant
	if id vagrant >/dev/null 2>&1; then
		echo '> the inherited vagrant account could not be removed; refusing to export the template' >&2
		exit 1
	fi
fi
# Written now, asserted now; sshd is not restarted, so the session survives.
install -D -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
# sshd -T refuses to run without a host key and without its privilege
# separation directory. The keys exist on a booted clone, but /run/sshd is
# ssh.service's RuntimeDirectory on 24.04: the build's openssh-server upgrade
# restarts ssh through its socket unit, which can leave ssh.service stopped -
# and the directory gone - while Packer's existing connection carries on. The
# shipped template is unaffected (ssh.socket starts the service on the first
# connection); only this check needs the directory to exist.
ssh-keygen -A >/dev/null
install -d -m 0755 /run/sshd
sshd_errors="$(mktemp)"
effective="$(sshd -T 2>"${sshd_errors}" || true)"
if ! grep -qx 'passwordauthentication no' <<<"${effective}"; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	grep -iE 'passwordauthentication|kbdinteractive' <<<"${effective}" >&2 || {
		echo '> sshd -T produced no output; its errors were:' >&2
		cat "${sshd_errors}" >&2
		ls -la /etc/ssh /run/sshd >&2 || true
		systemctl --no-pager status ssh.service ssh.socket >&2 || true
	}
	rm -f "${sshd_errors}"
	exit 1
fi
rm -f "${sshd_errors}"
echo '> sshd: password authentication disabled.'

echo '> Asserting the docker group is empty ...'
if [ -n "$(getent group docker | cut -d: -f4)" ]; then
	echo '> the docker group has members; refusing to export the template' >&2
	exit 1
fi

echo '> Prepared for finalization.'
