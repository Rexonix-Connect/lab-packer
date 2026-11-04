#!/bin/bash
# Final template preparation, run by `shutdown_command` after the Packer SSH
# session has done its last work. Only what cannot run while that session is
# still in use is here; everything else happened in finalize-prepare.sh, as
# an ordinary provisioner whose output Packer shows.
#
# Its job is to make the exported template carry no identity: no build
# account, no SSH host keys, no machine id, no cloud-init state.
set -euo pipefail

# Packer does not echo the shutdown command's output; put a failure on the VM
# console, which is visible in vCenter while Packer waits for the power-off.
trap 'rc=$?; msg="finalize.sh FAILED (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}"; \
      echo "${msg}" >&2; echo "${msg}" >/dev/console 2>/dev/null || true' ERR

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
rm -rf /tmp/vaultwarden-appliance /tmp/* /var/tmp/*
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
