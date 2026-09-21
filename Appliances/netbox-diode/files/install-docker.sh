#!/bin/bash
# The container runtime, and the one configuration decision that matters on
# this appliance: where its data root lives, and what it is allowed to publish.
#
# Two things are deliberate here.
#
# 1. data-root is moved to /srv/diode/docker BEFORE any image is pulled. The
#    baked container images and every named volume - the Diode PostgreSQL
#    cluster, the Redis append-only file - live under the data root, and those
#    are precisely the things that must not be able to fill the 60 GB root
#    disk inherited from the hardened base.
#
# 2. Nothing this appliance runs publishes a port on a non-loopback address.
#    Docker inserts its own rules ahead of ufw's chains, so a published port
#    is reachable whatever ufw says - which would silently defeat the whole
#    firewall story this repository tells. Binding the stack to 127.0.0.1 and
#    putting host nginx in front of it sidesteps that completely rather than
#    trying to make two firewall tools agree. verify.sh asserts it.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o APT::Get::Always-Include-Phased-Updates=true)

DATA_ROOT=/srv/diode
DOCKER_ROOT="${DATA_ROOT}/docker"

# install-datadisk.sh runs first and must have mounted it; without that Docker
# would put its images and volumes on the root disk the split exists to
# protect.
findmnt --noheadings --mountpoint "${DATA_ROOT}" >/dev/null

echo '> Adding the Docker repository ...'
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
	gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod 0644 /etc/apt/keyrings/docker.gpg
# shellcheck disable=SC1091
. /etc/os-release
cat >/etc/apt/sources.list.d/docker.list <<APT
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable
APT
apt-get "${APT_OPTS[@]}" update

echo '> Installing Docker Engine and the compose plugin ...'
apt-get "${APT_OPTS[@]}" install --yes \
	docker-ce \
	docker-ce-cli \
	containerd.io \
	docker-buildx-plugin \
	docker-compose-plugin

# Diode's own documentation asks for Docker 27.0.3 or newer; assert it rather
# than discover the gap after an image rebuild.
docker_major="$(docker --version | sed -n 's/Docker version \([0-9]*\)\..*/\1/p')"
if [ "${docker_major}" -lt 27 ]; then
	echo "> Docker ${docker_major} is below the 27 Diode requires"
	exit 1
fi
echo "> Docker $(docker --version | awk '{print $3}' | tr -d ,)"
docker compose version

echo "> Moving the Docker data root to ${DOCKER_ROOT} ..."
systemctl stop docker.socket docker.service || true
install -d -m 0710 -o root -g root "${DOCKER_ROOT}"
install -d -m 0755 -o root -g root /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "data-root": "/srv/diode/docker",
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  },
  "live-restore": true,
  "no-new-privileges": true
}
JSON
# docker.service must not start before the data disk is mounted: a Docker that
# came up on an empty data root would recreate empty volumes and the stack
# would look healthy while holding nothing.
install -d -m 0755 /etc/systemd/system/docker.service.d
install -m 0644 -o root -g root \
	"${PAYLOAD_DIR}/systemd/docker-datadisk.conf" \
	/etc/systemd/system/docker.service.d/10-datadisk.conf
systemctl daemon-reload
systemctl enable --now docker.service
timeout 60 bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done'

actual_root="$(docker info --format '{{.DockerRootDir}}')"
if [ "${actual_root}" != "${DOCKER_ROOT}" ]; then
	echo "> Docker root is ${actual_root}, expected ${DOCKER_ROOT}"
	exit 1
fi
echo "> Docker data root: ${actual_root}"
