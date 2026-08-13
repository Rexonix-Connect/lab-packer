#!/bin/bash
# Final template hardening script.
# Executed by `shutdown_command` at the very end of the Packer build so the
# SSH communicator remains available until this point.
set -euo pipefail

# Packer does not echo the shutdown command's output, so a failure here is
# otherwise silent: the build just times out waiting for a power-off that never
# comes. Put the reason somewhere a human can find it - the VM console, which is
# visible in vCenter for the fifteen minutes before Packer gives up.
trap 'rc=$?; msg="finalize.sh FAILED (exit ${rc}) at line ${LINENO}: ${BASH_COMMAND}"; \
      echo "${msg}" >&2; echo "${msg}" >/dev/console 2>/dev/null || true' ERR

echo '> Disabling SSH password authentication ...'
# sshd takes the FIRST value it obtains for a keyword, and /etc/ssh/sshd_config
# Includes sshd_config.d/*.conf near its top - so a directive written at the
# bottom of the main file loses to any drop-in. cloud-init ships
# 50-cloud-init.conf carrying PasswordAuthentication yes, because the build
# itself needs password SSH, and that is exactly such a drop-in. Editing only
# the main file therefore left password authentication ENABLED on every
# template this repo has published. Sorting ours as 00- puts it first, where it
# wins - and it keeps winning if cloud-init rewrites its own file on a clone.
# -D: the directory is not guaranteed to exist. Without it this fails
# instantly under set -e, and because Packer does not echo the shutdown
# command's output the build dies 15 minutes later saying only
# "timeout while waiting for machine to shutdown".
install -D -m 0644 /dev/stdin /etc/ssh/sshd_config.d/00-no-password-auth.conf <<'SSHD'
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
effective="$(sshd -T 2>/dev/null || true)"
if ! grep -qx 'passwordauthentication no' <<<"${effective}"; then
	echo '> SSH password authentication is still enabled; refusing to export the template' >&2
	grep -iE 'passwordauthentication|kbdinteractive' <<<"${effective}" >&2 || \
		echo '> sshd -T produced no output at all' >&2
	exit 1
fi
rm -f /etc/ssh/ssh_host_*
echo '> Writing hardened SSH configuration ...'
# Written here, after the Packer SSH communicator is finished, so restricting
# the key exchange/cipher/MAC sets cannot break the build's own connection.
# PasswordAuthentication is set in 00-no-password-auth.conf above, where
# the include order makes it effective; TCP forwarding stays enabled
# because labs rely on it.
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
PermitRootLogin no
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/issue.net
EOF
chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf
# Validate the sshd configuration. setup.sh already removed the host keys (so
# clones regenerate them on first boot) and `sshd -t` refuses to run with no
# host key present, so generate a throwaway key for the syntax check and
# remove the generated keys again afterwards.
ssh-keygen -A
sshd -t
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
