#!/bin/bash
# Final template preparation, run by `shutdown_command` after the Packer SSH
# session has done its last work.
#
# Its job is to make the exported template carry no identity and no secret:
# no rendered compose environment, no OAuth2 client secrets, no container
# volumes, no TLS key, no bootstrap state, no build account, no SSH host keys,
# no machine id. Everything here is recreated per deployment by
# diode-firstboot.py.
#
# What DOES survive, on purpose: /srv/diode/docker, because that is where the
# pulled container images live. They are the appliance - an air-gapped site
# cannot pull them - and they hold nothing deployment specific. verify.sh has
# already removed the volumes.
set -euo pipefail

# Packer does not echo the shutdown command's output, so a failure here is
# otherwise silent: the build just times out waiting for a power-off that
# never comes. Put the reason somewhere a human can find it - the VM console,
# which is visible in vCenter for the fifteen minutes before Packer gives up.
trap 'rc=$?; msg="finalize.sh FAILED (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}"; \
      echo "${msg}" >&2; echo "${msg}" >/dev/console 2>/dev/null || true' ERR

echo '> Stopping the appliance services ...'
systemctl stop nginx.service fail2ban.service || true
systemctl stop diode.service || true
systemctl stop docker.service docker.socket || true

echo '> Removing the build-time environment and OAuth2 client secrets ...'
rm -f /etc/diode/compose/.env
rm -f /etc/diode/compose/oauth2/client/client-credentials.json
rm -f /etc/diode/tls/diode.crt /etc/diode/tls/diode.key /etc/diode/tls/.self-signed
rm -rf /var/lib/diode-appliance
rm -f /root/diode-credentials.txt /etc/issue.d/60-diode.issue
# The rendered agent configuration and its credentials are per deployment too;
# only the template and the policy directory ship.
rm -f /etc/diode/agent/agent.yaml /etc/diode/agent/credentials.env
# The CA placeholder must exist in the image - Docker creates a DIRECTORY at a
# bind source that does not exist - but must be empty.
: >/etc/diode/netbox-ca.pem
chmod 0644 /etc/diode/netbox-ca.pem

echo '> Verifying no secret survived into the template ...'
# A cheap assertion with a large payoff: this is the property that makes the
# image safe to publish to a content library many people can deploy from.
for secret in /etc/diode/compose/.env \
	/etc/diode/compose/oauth2/client/client-credentials.json \
	/etc/diode/tls/diode.key /etc/diode/agent/credentials.env \
	/root/diode-credentials.txt; do
	if [ -e "${secret}" ]; then
		echo "> ${secret} still exists; refusing to export the template" >&2
		exit 1
	fi
done
if [ -n "$(docker volume ls -q 2>/dev/null || true)" ]; then
	echo '> container volumes still exist; refusing to export the template' >&2
	docker volume ls >&2 || true
	exit 1
fi

echo '> Clearing build-time state from the data disk ...'
rm -f /srv/diode/backups/* 2>/dev/null || true

echo '> Resetting the deploy-time nginx snippets ...'
printf '# Written by diode-firstboot.py.\nserver_name _;\n' \
	>/etc/nginx/snippets/diode-server-name.conf
printf '# Written by diode-firstboot.py.\ndeny all;\n' \
	>/etc/nginx/snippets/diode-metrics.conf
printf '# Written by diode-firstboot.py.\n' \
	>/etc/nginx/snippets/diode-hsts.conf

# Inherited from the base image, which until recently shipped both of these: a
# `vagrant` account its own finalize failed to delete (userdel refuses while
# the account owns the shutdown session, and the failure was swallowed) and
# password authentication still enabled, because `PasswordAuthentication no`
# was written to the bottom of sshd_config where cloud-init's
# 50-cloud-init.conf drop-in outranks it. Together they are a password login on
# every deployed appliance. This image clones an already-built base, so it
# cannot wait for that base to be rebuilt to stop shipping them.
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
# -D: the directory is not guaranteed to exist. Without it this fails
# instantly under set -e, and because Packer does not echo the shutdown
# command's output the build dies 15 minutes later saying only
# "timeout while waiting for machine to shutdown".
install -D -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
ssh-keygen -A >/dev/null
effective="$(sshd -T 2>/dev/null || true)"
if ! grep -qx 'passwordauthentication no' <<<"${effective}"; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	grep -iE 'passwordauthentication|kbdinteractive' <<<"${effective}" >&2 ||
		echo '> sshd -T produced no output at all' >&2
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
rm -rf /tmp/diode-appliance /tmp/* /var/tmp/*
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
