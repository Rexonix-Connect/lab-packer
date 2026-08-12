#!/bin/bash
# Take the cloud-init datasource off the kernel command line.
#
# The ISO builds used to boot the installer with
#
#     linux /casper/vmlinuz --- autoinstall ds="nocloud"
#
# and casper appends everything after `---` to the *installed* system's kernel
# command line. The boot commands now read
#
#     linux /casper/vmlinuz autoinstall ds="nocloud" ---
#
# so nothing leaks, but every template built before that change still carries
# the parameter, and this script is what clears them.
#
# `ds=` does not mean "prefer this datasource": cloud-init treats
# it as "use only this one", overriding datasource_list entirely. So every image
# this repo builds came up pinned to NoCloud with a cmdline seed:
#
#     Kernel command line set to use a single datasource DataSourceNoCloud .
#     Loaded datasource DataSourceNoCloud [seed=cmdline][dsmode=local]
#
# which makes `datasource_list: [NoCloud, ConfigDrive, VMware, OVF, None]` in
# /etc/cloud/cloud.cfg.d/90_dpkg.cfg a dead letter. VMware guestinfo and OVF are
# never consulted, so nothing delivered through them - the deploy form's
# user-data, public-keys and password, and the test harness's diagnostics
# account - is ever applied. Only what ovf-settings.py reads out of the OVF
# environment itself gets through.
#
# The boot commands no longer propagate it, but a template built before that
# change still carries it, and the appliance clones such a template. Stripping
# it here fixes both, and is a no-op on an image that never had it.
set -euo pipefail

echo '> Unpinning the cloud-init datasource from the kernel command line ...'

if [ -f /etc/default/grub ]; then
	# Only the ds= token, and only when present, so an unrelated command line is
	# left byte-identical. The fully-quoted form (ds="nocloud;s=...") has to be
	# matched before the bare one, or the bare pattern eats the quote that
	# closes GRUB_CMDLINE_LINUX itself and truncates the file's syntax.
	#
	# \b is a word boundary here, not a backspace: this runs under GNU sed and
	# GNU grep, which is what every image this repo builds ships. It is what
	# keeps `rootds=nocloudy` from being mangled. Verified against eight real
	# GRUB_CMDLINE forms, including that one and both quoting styles.
	sed -i -E '
		s/\bds="nocloud[^"]*"//g
		s/\bds=nocloud[^ "]*//g
		s/[[:space:]]{2,}/ /g
		s/="[[:space:]]+/="/
		s/[[:space:]]+"$/"/
	' /etc/default/grub
	if command -v update-grub >/dev/null 2>&1; then
		update-grub
	else
		grub-mkconfig -o /boot/grub/grub.cfg
	fi
fi

# Whatever the source, the generated configuration is what the next boot reads,
# so that is what gets asserted. A leftover here means the image would come up
# pinned again and every guestinfo- or OVF-delivered setting would be ignored -
# silently, which is how this survived four templates and three test rounds.
for config in /boot/grub/grub.cfg /etc/default/grub; do
	[ -f "${config}" ] || continue
	if grep -qE '\bds=nocloud' "${config}"; then
		echo "ds=nocloud is still present in ${config} after the rewrite:" >&2
		grep -nE '\bds=nocloud' "${config}" >&2
		exit 1
	fi
done

echo '> Cloud-init will consult its full datasource_list on the next boot.'
