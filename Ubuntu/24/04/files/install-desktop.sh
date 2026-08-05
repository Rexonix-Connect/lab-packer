#!/bin/bash
set -euo pipefail

# Runs on the booted system rather than as an autoinstall late-command: the
# desktop task includes snap-backed packages whose maintainer scripts need a
# running snapd, which does not exist in the installer chroot, and the long
# download no longer counts against the Packer SSH wait timeout.
if [ "${INSTALL_DESKTOP:-false}" != "true" ]; then
	echo '> Server flavor; skipping the desktop task.'
	exit 0
fi

echo '> Installing the Ubuntu desktop task and GUI guest integration ...'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes ubuntu-desktop^ open-vm-tools-desktop
