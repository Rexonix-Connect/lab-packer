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
echo '> Removing vagrant account ...'
rm -f /etc/sudoers.d/vagrant
userdel -r vagrant || true
echo '> Cleaning temporary files and shell histories ...'
rm -rf /tmp/* /var/tmp/*
find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.python_history' \) -exec truncate -s 0 {} \; 2>/dev/null || true
echo '> Shutting down ...'
shutdown -P now
