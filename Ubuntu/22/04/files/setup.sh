#!/bin/bash

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
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# optional: cleaning cloud-init
echo '> Cleaning cloud-init'
rm -rf /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -rf /etc/cloud/cloud.cfg.d/99-installer.cfg
echo 'datasource_list: [ VMware, NoCloud, ConfigDrive ]' | tee /etc/cloud/cloud.cfg.d/90_dpkg.cfg
/usr/bin/cloud-init clean
