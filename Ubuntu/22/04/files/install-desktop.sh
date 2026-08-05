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

export DEBIAN_FRONTEND=noninteractive
# Phased updates are randomly held back per machine-id; a held phased library
# can make desktop task dependencies unresolvable ("held broken packages"),
# so include them all during the build.
APT_OPTS=(-o APT::Get::Always-Include-Phased-Updates=true --yes)

apt-get update

echo '> Installing GUI guest integration ...'
apt-get install "${APT_OPTS[@]}" open-vm-tools-desktop

echo '> Installing the Ubuntu desktop task ...'
# The Mesa Amber legacy-GPU stack in the desktop task is uninstallable next
# to current Mesa on amd64 (libglapi-amber Breaks libglapi-mesa) and serves
# pre-GL2 hardware only; VMware guests render via vmwgfx on current Mesa.
apt-get install "${APT_OPTS[@]}" ubuntu-desktop^ libgl1-amber-dri- libglapi-amber-
