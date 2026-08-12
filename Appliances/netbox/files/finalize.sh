#!/bin/bash
# Final template preparation, run by `shutdown_command` after the Packer SSH
# session has done its last work.
#
# Its job is to make the exported template carry no identity and no secret:
# no NetBox configuration, no TLS key, no bootstrap state, no build account,
# no SSH host keys, no machine id. Everything here is recreated per deployment
# by netbox-firstboot.py.
set -euo pipefail

echo '> Stopping the appliance services ...'
systemctl stop netbox.service netbox-rq.service nginx.service fail2ban.service || true
systemctl stop postgresql redis-server || true

echo '> Clearing build-time state from the data disk ...'
# The data disk itself must survive: it holds NetBox, its virtual environment
# and the migrated database, all of which ship inside the template. What must
# not survive is anything generated during the build.
rm -f /srv/netbox/backups/* 2>/dev/null || true
find /srv/netbox/netbox/media -mindepth 1 -delete 2>/dev/null || true

echo '> Removing the build-time NetBox configuration and TLS material ...'
# The migrated database stays: the local cluster authenticates by peer over the
# Unix socket, so it holds no password, and it contains no user - the superuser
# is created on first boot. What is removed is everything that would otherwise
# be identity: SECRET_KEY, the API token pepper, and the certificate.
rm -f /etc/netbox/appliance.json
rm -f /etc/netbox/tls/netbox.crt /etc/netbox/tls/netbox.key /etc/netbox/tls/.self-signed
rm -rf /var/lib/netbox-appliance
rm -f /root/netbox-credentials.txt /etc/issue.d/60-netbox.issue

echo '> Resetting the deploy-time nginx snippets ...'
printf '# Written by netbox-firstboot.py.\nserver_name _;\n' \
	>/etc/nginx/snippets/netbox-server-name.conf
printf '# Written by netbox-firstboot.py.\ndeny all;\n' \
	>/etc/nginx/snippets/netbox-metrics.conf
printf '# Written by netbox-firstboot.py.\n' \
	>/etc/nginx/snippets/netbox-hsts.conf

# Inherited from the base image, which until recently shipped both of these: a
# `vagrant` account its own finalize failed to delete (userdel refuses while the
# account owns the shutdown session, and the failure was swallowed) and password
# authentication still enabled, because `PasswordAuthentication no` was written
# to the bottom of sshd_config where cloud-init's 50-cloud-init.conf drop-in
# outranks it. Together they are a password login on every deployed appliance.
# The appliance clones an already-built base, so it cannot wait for that base to
# be rebuilt to stop shipping them.
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
install -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
ssh-keygen -A >/dev/null
if ! sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	sshd -T 2>/dev/null | grep -i 'passwordauthentication\|kbdinteractive' >&2
	exit 1
fi
rm -f /etc/ssh/ssh_host_*

echo '> Removing the build account ...'
build_user="${BUILD_USERNAME:-pkrbuild}"
# Drop the authorized key first, so even a failure below cannot leave an
# account the build runner's key can log into.
rm -f "/home/${build_user}/.ssh/authorized_keys"
rm -f /etc/sudoers.d/90-cloud-init-users
# The account still owns this login session, so userdel may refuse; -f is the
# documented way through that.
userdel -r "${build_user}" 2>/dev/null ||
	userdel -f -r "${build_user}" 2>/dev/null ||
	true
rm -rf "/home/${build_user}"
if id "${build_user}" >/dev/null 2>&1; then
	echo "> the build account ${build_user} could not be removed; refusing to export the template"
	exit 1
fi

echo '> Cleaning temporary files and shell histories ...'
rm -rf /tmp/netbox-appliance /tmp/* /var/tmp/*
find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.python_history' \) -exec truncate -s 0 {} \; 2>/dev/null || true

echo '> Cleaning SSH host keys ...'
rm -f /etc/ssh/ssh_host_*

echo '> Resetting cloud-init so the deploy form applies on first boot ...'
/usr/bin/cloud-init clean --logs --seed || true

echo '> Cleaning the machine-id ...'
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo '> Shutting down ...'
shutdown -P now
