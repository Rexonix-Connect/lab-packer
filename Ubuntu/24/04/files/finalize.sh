#!/bin/bash
# Final template hardening script.
# Executed by `shutdown_command` at the very end of the Packer build so the
# SSH communicator remains available until this point.
set -euo pipefail

echo '> Disabling SSH password authentication ...'
# sshd takes the FIRST value it obtains for a keyword, and /etc/ssh/sshd_config
# Includes sshd_config.d/*.conf near its top - so a directive written at the
# bottom of the main file loses to any drop-in. cloud-init ships
# 50-cloud-init.conf carrying PasswordAuthentication yes, because the build
# itself needs password SSH, and that is exactly such a drop-in. Editing only
# the main file therefore left password authentication ENABLED on every
# template this repo has published. Sorting ours as 00- puts it first, where it
# wins - and it keeps winning if cloud-init rewrites its own file on a clone.
install -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
# Also correct the main file, which is where an operator looks first.
if grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config; then
	sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/g' /etc/ssh/sshd_config
else
	echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
# Assert the EFFECTIVE value rather than the file contents; the include order is
# the entire point. sshd needs a host key to answer, and setup.sh removed them
# so clones regenerate their own, so use throwaway ones and drop them again.
ssh-keygen -A >/dev/null
if ! sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	sshd -T 2>/dev/null | grep -i 'passwordauthentication\|kbdinteractive' >&2
	exit 1
fi
rm -f /etc/ssh/ssh_host_*
echo '> Removing vagrant account ...'
# Drop the credentials first, so even a failure below cannot leave a usable
# login behind.
rm -f /home/vagrant/.ssh/authorized_keys
rm -f /etc/sudoers.d/vagrant
# This script runs as the shutdown command over vagrant's OWN SSH session, so
# userdel refuses: "user vagrant is currently used by process N". The bare
# `|| true` that used to be here swallowed that refusal silently, and every
# template shipped with the account and its build password intact - reachable
# over SSH once password authentication turned out to be enabled too.
userdel -r vagrant 2>/dev/null ||
	userdel -f -r vagrant 2>/dev/null ||
	true
rm -rf /home/vagrant
if id vagrant >/dev/null 2>&1; then
	echo '> the vagrant build account could not be removed; refusing to export the template' >&2
	exit 1
fi
echo '> Cleaning temporary files and shell histories ...'
rm -rf /tmp/* /var/tmp/*
find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.python_history' \) -exec truncate -s 0 {} \; 2>/dev/null || true
echo '> Shutting down ...'
shutdown -P now
