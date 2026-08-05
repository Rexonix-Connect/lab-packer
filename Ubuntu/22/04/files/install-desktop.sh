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
# Phased updates are randomly held back per machine-id; include them all so
# template patch state is deterministic.
APT_OPTS=(-o APT::Get::Always-Include-Phased-Updates=true --yes)

apt-get update

echo '> Installing GUI guest integration ...'
apt-get install "${APT_OPTS[@]}" open-vm-tools-desktop

echo '> Resolving the ubuntu-desktop task package list ...'
# apt's task^ syntax force-installs every task member, and on noble amd64 the
# task ships libgl1-amber-dri, whose Mesa Amber legacy-GPU stack is
# uninstallable next to current Mesa (libglapi-amber Breaks libglapi-mesa),
# making the ^ form unresolvable even on a clean system. Expand the member
# list from the package indexes instead and drop the Amber DRI provider,
# which only serves pre-OpenGL-2.1 physical GPUs; VMware guests render via
# vmwgfx on current Mesa.
mapfile -t packages < <(apt-cache dumpavail | awk -v RS='' '{
	pkg=""; task=""
	n=split($0, lines, "\n")
	for(i=1;i<=n;i++){
		if(lines[i]~/^Package: /){pkg=substr(lines[i],10)}
		else if(lines[i]~/^Task: /){task=substr(lines[i],7)}
	}
	if(pkg!="" && task!=""){
		m=split(task, tasks, /, */)
		for(j=1;j<=m;j++) if(tasks[j]=="ubuntu-desktop"){print pkg; break}
	}
}' | sort -u | grep -v '^libgl1-amber-dri$')

if [ "${#packages[@]}" -lt 100 ]; then
	echo "> Task expansion produced only ${#packages[@]} packages; refusing to continue."
	exit 1
fi

echo "> Installing the Ubuntu desktop task (${#packages[@]} packages) ..."
apt-get install "${APT_OPTS[@]}" "${packages[@]}"
