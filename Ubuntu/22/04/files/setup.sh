#!/bin/bash
set -euo pipefail

echo '> Cleaning all audit logs ...'
if [ -f /var/log/audit/audit.log ]; then
cat /dev/null > /var/log/audit/audit.log
fi
if [ -f /var/log/wtmp ]; then
cat /dev/null > /var/log/wtmp
fi
if [ -f /var/log/lastlog ]; then
cat /dev/null > /var/log/lastlog
fi
echo '> Verifying known-CVE kernel module mitigations ...'
for mod in algif_aead act_pedit esp4 esp6 rxrpc; do
	if ! modprobe -n -v "${mod}" 2>/dev/null | grep -q '/bin/false'; then
		echo "> ${mod} is not blocked by modprobe configuration"
		exit 1
	fi
	if grep -qE "^${mod} " /proc/modules; then
		echo "> ${mod} is loaded; refusing to template a potentially vulnerable image"
		exit 1
	fi
done
echo '> Verifying hardening sysctls ...'
for kv in kernel.dmesg_restrict=1 kernel.kptr_restrict=1 kernel.yama.ptrace_scope=1 kernel.unprivileged_bpf_disabled=2 net.core.bpf_jit_harden=2 fs.protected_fifos=2 fs.protected_regular=2; do
	key="${kv%%=*}"
	want="${kv##*=}"
	have="$(sysctl -n "${key}")"
	if [ "${have}" != "${want}" ]; then
		echo "> sysctl ${key} is ${have}, expected ${want}"
		exit 1
	fi
done
echo '> Verifying unattended-upgrades is enabled ...'
if ! apt-config dump APT::Periodic::Unattended-Upgrade | grep -q '"1"'; then
	echo '> unattended-upgrades periodic run is not enabled'
	exit 1
fi
# Configures firewall defaults; SSH must be explicitly allowed before enabling.
echo '> Configuring ufw firewall ...'
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
# Cleans SSH keys.
echo '> Cleaning SSH keys ...'
rm -f /etc/ssh/ssh_host_*
# Sets hostname to localhost.
echo '> Setting hostname to localhost ...'
cat /dev/null > /etc/hostname
hostnamectl set-hostname localhost
# Cleans apt-get.
echo '> Cleaning apt-get ...'
apt-get clean
rm -rf /var/lib/apt/lists/*
# Reduces the default ext4 reserved blocks so template clones expose more usable
# root space in df while still leaving a small safety buffer for root-owned files.
echo '> Reducing reserved root filesystem blocks ...'
ROOT_DEVICE="$(findmnt -no SOURCE /)"
if command -v tune2fs >/dev/null 2>&1 && [[ "${ROOT_DEVICE}" == /dev/* ]] && tune2fs -l "${ROOT_DEVICE}" >/dev/null 2>&1; then
	tune2fs -m 1 "${ROOT_DEVICE}"
else
	echo "> Skipping reserved block tuning for root source ${ROOT_DEVICE}"
fi
# Cleans the machine-id.
echo '> Cleaning the machine-id ...'
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# optional: cleaning cloud-init
echo '> Cleaning cloud-init'
rm -rf /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -rf /etc/cloud/cloud.cfg.d/99-installer.cfg
echo 'datasource_list: [ VMware, NoCloud, ConfigDrive ]' | tee /etc/cloud/cloud.cfg.d/90_dpkg.cfg
/usr/bin/cloud-init clean --logs --seed
# Marks the finalizer script (uploaded via `file` provisioner) executable so
# `shutdown_command` can invoke it.
chmod 700 /tmp/packer-finalize-template.sh
