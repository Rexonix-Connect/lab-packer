#!/bin/bash
# Final template preparation, run by `shutdown_command` after the Packer SSH
# session has done its last work.
#
# Its job is to make the exported template carry no identity and no secret: no
# admin token, no settings, no TLS key, no volume id, no bootstrap state, no
# database, no build account, no SSH host keys, no machine id. verify.sh has
# already dropped the database and emptied the data directory; this removes
# the rest, and every one of these is recreated per deployment.
set -euo pipefail

# Packer does not echo the shutdown command's output; put a failure on the VM
# console, which is visible in vCenter while Packer waits for the power-off.
trap 'rc=$?; msg="finalize.sh FAILED (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}"; \
      echo "${msg}" >&2; echo "${msg}" >/dev/console 2>/dev/null || true' ERR

echo '> Stopping the appliance services ...'
systemctl stop vaultwarden.service nginx.service fail2ban.service || true
systemctl stop 'postgresql@*' || true

echo '> Asserting the data disk carries no instance ...'
if [ -n "$(find /srv/vaultwarden/data /srv/vaultwarden/backups -mindepth 1 -print -quit 2>/dev/null)" ]; then
	echo '> /srv/vaultwarden still holds data or backups; refusing to export the template' >&2
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

echo '> Removing appliance-owned firewall rules ...'
# The first-boot bootstrap owns these (comment vaultwarden-https/-ssh) and
# creates them from the deploy form. The build's restore test runs a reconcile,
# which may have added some; the template ships with the base SSH rule only.
ufw status numbered 2>/dev/null |
	sed -nE 's/^\[ *([0-9]+)\].*# vaultwarden-(https|ssh)[[:space:]]*$/\1/p' |
	sort -rn | while read -r number; do
	ufw --force delete "${number}" >/dev/null
done
ufw allow ssh >/dev/null
if ufw status | grep -q 'vaultwarden-'; then
	echo '> appliance firewall rules survived; refusing to export the template' >&2
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
install -D -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
ssh-keygen -A >/dev/null
effective="$(sshd -T 2>/dev/null || true)"
if ! grep -qx 'passwordauthentication no' <<<"${effective}"; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	exit 1
fi
rm -f /etc/ssh/ssh_host_*

echo '> Removing the build account ...'
# Passed by the shutdown command; SUDO_USER is the same account by another
# route (this script runs under the build account's own sudo), and pkrbuild
# only the last resort. A wrong guess here would export the build account and
# its authorized key inside the template.
build_user="${BUILD_USERNAME:-${SUDO_USER:-pkrbuild}}"
if [ "${build_user}" = 'root' ]; then
	echo '> refusing to treat root as the build account' >&2
	exit 1
fi
rm -f "/home/${build_user}/.ssh/authorized_keys"
rm -f /etc/sudoers.d/90-cloud-init-users
userdel -r "${build_user}" 2>/dev/null ||
	userdel -f -r "${build_user}" 2>/dev/null ||
	true
rm -rf "/home/${build_user}"
if id "${build_user}" >/dev/null 2>&1; then
	echo "> the build account ${build_user} could not be removed; refusing to export the template"
	exit 1
fi
if [ -n "$(getent group docker | cut -d: -f4)" ]; then
	echo '> the docker group has members; refusing to export the template' >&2
	exit 1
fi

echo '> Cleaning temporary files and shell histories ...'
rm -rf /tmp/vaultwarden-appliance /tmp/* /var/tmp/*
find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.python_history' \) -exec truncate -s 0 {} \; 2>/dev/null || true

echo '> Resetting cloud-init so the deploy form applies on first boot ...'
/usr/bin/cloud-init clean --logs --seed || true

echo '> Cleaning the machine-id ...'
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo '> Shutting down ...'
shutdown -P now
