#!/bin/bash
# Final template hardening script.
# Executed by `shutdown_command` at the very end of the Packer build so the
# SSH communicator remains available until this point.
set -euo pipefail

echo '> Disabling SSH password authentication ...'
if grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+' /etc/ssh/sshd_config; then
	sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/g' /etc/ssh/sshd_config
else
	echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
echo '> Writing hardened SSH configuration ...'
# Written here, after the Packer SSH communicator is finished, so restricting
# the key exchange/cipher/MAC sets cannot break the build's own connection.
# PasswordAuthentication is intentionally left to the block above; TCP
# forwarding stays enabled because labs rely on it.
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
rm -f /etc/sudoers.d/vagrant
userdel -r vagrant || true
echo '> Cleaning temporary files and shell histories ...'
rm -rf /tmp/* /var/tmp/*
find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.python_history' \) -exec truncate -s 0 {} \; 2>/dev/null || true
echo '> Shutting down ...'
shutdown -P now
