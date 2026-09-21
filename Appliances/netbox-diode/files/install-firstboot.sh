#!/bin/bash
# Install the first-boot bootstrap and wire the services to it, so a
# deployment that fails to bootstrap stays visibly down instead of running a
# stack with empty passwords.
set -euo pipefail

echo '> Installing the shared appliance modules ...'
# One copy in the repository, installed into every image, imported by path at
# run time. The outbound-proxy rules in particular are not obvious enough to
# be worth maintaining twice - strict validation instead of escaping, because
# the value lands in three differently quoted contexts - and two copies would
# drift.
install -d -m 0755 -o root -g root /usr/local/lib/lab-appliance
for module in "${SHARED_DIR}"/*.py; do
	install -m 0644 -o root -g root "${module}" \
		"/usr/local/lib/lab-appliance/$(basename "${module}")"
	python3 -m py_compile "/usr/local/lib/lab-appliance/$(basename "${module}")"
done
# An empty SHARED_DIR would leave the loop a no-op and the failure would only
# appear at first boot, on a deployed appliance, as a missing module.
if [ ! -f /usr/local/lib/lab-appliance/proxy.py ]; then
	echo '> the shared proxy module was not installed' >&2
	exit 1
fi

echo '> Installing the first-boot bootstrap ...'
install -m 0700 -o root -g root \
	"${PAYLOAD_DIR}/diode-firstboot.py" /usr/local/sbin/diode-firstboot.py
python3 -m py_compile /usr/local/sbin/diode-firstboot.py

install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/diode-bootstrap.service" /etc/systemd/system/diode-bootstrap.service
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/diode-reconcile.service" /etc/systemd/system/diode-reconcile.service

for unit in diode nginx; do
	install -d -m 0755 "/etc/systemd/system/${unit}.service.d"
	install -m 0644 -o root -g root \
		"${PAYLOAD_DIR}/systemd/diode-requires.conf" \
		"/etc/systemd/system/${unit}.service.d/20-bootstrap.conf"
done

# Both units are pulled into multi-user.target, and cloud-final.service is
# ordered after multi-user.target. Ordering either of them after cloud-final
# closes a dependency cycle, and systemd breaks a cycle by deleting jobs: on
# the NetBox appliance it dropped the bootstrap (so nothing that Requires= it
# started) and cloud-final itself (so cloud-init never finished and the deploy
# form stopped being applied), logging nothing against any unit. The appliance
# booted in thirteen seconds and served nothing. Fail the build rather than
# ship that again.
for unit in diode-bootstrap diode-reconcile; do
	# After= only: Requires= and Wants= pull a unit into the transaction but
	# impose no ordering, so they cannot close the cycle on their own.
	if grep -qE '^After=.*cloud-(final|config)\.service' \
		"/etc/systemd/system/${unit}.service"; then
		echo "${unit}.service orders itself against a late cloud-init unit;" >&2
		echo 'that creates a dependency cycle through multi-user.target.' >&2
		exit 1
	fi
done

systemctl daemon-reload
systemctl enable diode-bootstrap.service diode-reconcile.service
echo '> First-boot bootstrap installed.'
