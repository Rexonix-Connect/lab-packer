#!/bin/bash
# Prepare the data disk that add-vm-disk.py just attached, and mount it at
# /srv/netbox.
#
# Everything that grows lives here - the NetBox installation, the PostgreSQL
# cluster and the backups - so the 60 GB root inherited from the hardened base
# cannot be filled by NetBox's own data.
#
# The filesystem is made on the whole device with no partition table. That is
# deliberate: growing the volume afterwards is then a single resize2fs, with no
# partition table to extend first, which is what makes enlarging the disk in
# the deploy wizard a hands-off operation (see netbox-datadisk.service).
set -euo pipefail

MOUNTPOINT=/srv/netbox
LABEL=netbox-data
# Matches the unit number add-vm-disk.py attaches at: host and LUN vary, the
# channel and target do not.
BY_PATH_GLOB='/dev/disk/by-path/*-scsi-*:0:1:0'

if findmnt --noheadings --target "${MOUNTPOINT}" --mountpoint "${MOUNTPOINT}" >/dev/null 2>&1; then
	echo "> ${MOUNTPOINT} is already a mount point; nothing to do"
	exit 0
fi

echo '> Rescanning the SCSI bus for the new disk ...'
for host in /sys/class/scsi_host/host*; do
	if [ -w "${host}/scan" ]; then
		echo '- - -' >"${host}/scan" 2>/dev/null || true
	fi
done

root_source="$(findmnt -no SOURCE /)"
root_disk="$(lsblk -no PKNAME "${root_source}" 2>/dev/null | head -n 1 || true)"
if [ -z "${root_disk}" ]; then
	# The root filesystem sits on a whole device rather than a partition.
	root_disk="$(basename "${root_source}")"
fi
echo "> Root filesystem is on /dev/${root_disk}"

find_data_disk() {
	# Preferred: the deterministic path for the unit the disk was attached at.
	local candidate
	for candidate in ${BY_PATH_GLOB}; do
		if [ -b "${candidate}" ]; then
			readlink -f "${candidate}"
			return 0
		fi
	done
	# Fallback: exactly one whole disk that is not the root disk and carries
	# no filesystem or partitions. Anything ambiguous is refused rather than
	# guessed at - a mkfs on the wrong device destroys the base image.
	local found=()
	local name
	while read -r name; do
		[ "${name}" = "${root_disk}" ] && continue
		if [ -n "$(lsblk -no FSTYPE "/dev/${name}" 2>/dev/null | tr -d ' \n')" ]; then
			continue
		fi
		found+=("/dev/${name}")
	done < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" { print $1 }')
	if [ "${#found[@]}" -eq 1 ]; then
		echo "${found[0]}"
		return 0
	fi
	return 1
}

echo '> Waiting for the data disk to appear ...'
device=''
for _ in $(seq 1 30); do
	udevadm settle --timeout=5 >/dev/null 2>&1 || true
	if device="$(find_data_disk)"; then
		break
	fi
	device=''
	sleep 2
done
if [ -z "${device}" ]; then
	echo '> No unused data disk appeared. Devices seen:'
	lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS
	exit 1
fi
echo "> Data disk: ${device} ($(lsblk -dn -o SIZE "${device}" | tr -d ' '))"

# Refuse to touch anything that already holds data. add-vm-disk.py only ever
# attaches a fresh disk, so a signature here means the wrong device was picked.
if [ -n "$(lsblk -no FSTYPE "${device}" | tr -d ' \n')" ]; then
	echo "> ${device} already contains a filesystem; refusing to format it"
	lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS "${device}"
	exit 1
fi
if [ "${device}" = "/dev/${root_disk}" ]; then
	echo "> ${device} is the root disk; refusing to format it"
	exit 1
fi

echo "> Creating an ext4 filesystem on ${device} ..."
mkfs.ext4 -q -L "${LABEL}" "${device}"
udevadm settle --timeout=10 >/dev/null 2>&1 || true

uuid="$(blkid -s UUID -o value "${device}")"
if [ -z "${uuid}" ]; then
	echo "> could not read a UUID back from ${device}"
	exit 1
fi

echo "> Mounting ${MOUNTPOINT} (UUID=${uuid}) ..."
install -d -m 0755 -o root -g root "${MOUNTPOINT}"
# nofail keeps a missing disk from dropping a clone into emergency mode; the
# RequiresMountsFor= drop-ins are what stop NetBox serving without it, which is
# a visible failure rather than a silent one. nodev/nosuid match the hardened
# base's posture - but not noexec, because the virtual environment lives here.
if ! grep -q "^UUID=${uuid}" /etc/fstab; then
	printf 'UUID=%s %s ext4 defaults,nofail,nodev,nosuid 0 2\n' \
		"${uuid}" "${MOUNTPOINT}" >>/etc/fstab
fi
systemctl daemon-reload
mount "${MOUNTPOINT}"
findmnt --noheadings --mountpoint "${MOUNTPOINT}"

echo '> Data disk ready.'
df -h "${MOUNTPOINT}"
