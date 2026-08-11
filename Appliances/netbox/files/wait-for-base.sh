#!/bin/bash
# Wait for the cloned base image to finish its own first boot, then prove the
# clone source really was the hardened Ubuntu 24.04 server template.
#
# Everything downstream assumes that baseline. A stale, wrong or unhardened
# source has to fail here, loudly, rather than produce a NetBox appliance that
# quietly lacks the hardening it advertises.
set -euo pipefail

echo '> Waiting for cloud-init to settle ...'
# --wait returns non-zero for a degraded run; the interesting failures are
# asserted individually below, so report the status instead of aborting on it.
cloud-init status --wait --long || true
echo "> cloud-init reports: $(cloud-init status || true)"

echo '> Verifying the build account ...'
id "${BUILD_USERNAME}" >/dev/null

echo '> Verifying the base operating system ...'
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID}" != "ubuntu" ] || [ "${VERSION_ID}" != "24.04" ]; then
	echo "> unexpected base image: ${ID:-?} ${VERSION_ID:-?}; expected ubuntu 24.04"
	exit 1
fi

echo '> Verifying the hardened baseline came across with the clone ...'
if [ ! -x /usr/local/sbin/ovf-settings.py ]; then
	echo '> /usr/local/sbin/ovf-settings.py is missing; the clone source is not a lab-packer template'
	exit 1
fi
systemctl is-enabled ovf-settings.service >/dev/null
id recovery >/dev/null
if ! systemctl is-enabled auditd >/dev/null 2>&1; then
	echo '> auditd is not enabled; the clone source is not the hardened template'
	exit 1
fi
for mod in algif_aead act_pedit esp4 esp6 rxrpc cramfs freevxfs jffs2 hfs hfsplus dccp sctp rds tipc; do
	if ! modprobe -n -v "${mod}" 2>/dev/null | grep -q '/bin/false'; then
		echo "> ${mod} is not blocked; the clone source is not the hardened template"
		exit 1
	fi
done
shm_opts="$(findmnt -no OPTIONS /dev/shm || true)"
for opt in nodev nosuid noexec; do
	case ",${shm_opts}," in
	*",${opt},"*) ;;
	*)
		echo "> /dev/shm is missing mount option ${opt} (have: ${shm_opts}); the clone source is not the hardened template"
		exit 1
		;;
	esac
done
echo '> Hardened baseline confirmed.'
