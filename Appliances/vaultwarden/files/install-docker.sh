#!/bin/bash
# The container runtime, configured so it cannot open the firewall.
#
# Docker's default is to program iptables itself: every published port gets a
# DNAT rule in a chain that ufw's INPUT rules never see, so `ufw deny` does not
# protect a published port. That is the classic way a "firewalled" Docker host
# ends up exposing a database. This appliance avoids the whole class instead of
# patching it with DOCKER-USER rules:
#
#   - iptables and ip6tables management is off, and there is no default bridge,
#     so the daemon never writes a single netfilter rule;
#   - the Vaultwarden container uses the host network and binds 127.0.0.1:8000,
#     so it has no published port to forward in the first place;
#   - ufw remains the only thing that decides what is reachable, and the
#     build asserts no Docker chain exists.
#
# The image is pulled here, by digest, and ships inside the template, so a
# deployment in a network with no route to Docker Hub still starts.
set -euo pipefail

: "${VAULTWARDEN_IMAGE:?VAULTWARDEN_IMAGE must be repository:tag@sha256:digest}"
digest="${VAULTWARDEN_IMAGE##*@}"
repository="${VAULTWARDEN_IMAGE%@*}"
repository="${repository%:*}"

echo '> Configuring the Docker daemon ...'
install -d -m 0755 /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "iptables": false,
  "ip6tables": false,
  "bridge": "none",
  "ip-forward": false,
  "no-new-privileges": true,
  "live-restore": false,
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF
chmod 0644 /etc/docker/daemon.json

# The API stays the stock Unix socket, root-only: nobody is put in the docker
# group, which is root-equivalent, and the listener check below fails the build
# if anything ever adds a TCP -H.
systemctl daemon-reload
systemctl enable docker.service containerd.service
systemctl restart docker.service

echo '> Verifying Docker cannot touch the firewall ...'
docker info --format '{{.ServerVersion}} {{.Driver}} {{.LoggingDriver}}'
if iptables -S 2>/dev/null | grep -q DOCKER || ip6tables -S 2>/dev/null | grep -q DOCKER ||
	nft list ruleset 2>/dev/null | grep -qi docker; then
	echo '> Docker created netfilter rules despite iptables=false'
	iptables -S || true
	exit 1
fi
if ip link show docker0 >/dev/null 2>&1; then
	echo '> docker0 exists despite bridge=none'
	exit 1
fi
if ss -H -ltn | grep -qE ':(2375|2376) '; then
	echo '> the Docker API is listening on TCP'
	exit 1
fi
members="$(getent group docker | cut -d: -f4)"
if [ -n "${members}" ]; then
	echo "> the docker group has members (${members}); it is root-equivalent"
	exit 1
fi

echo "> Pulling ${VAULTWARDEN_IMAGE} ..."
docker pull --quiet "${VAULTWARDEN_IMAGE}"
# The pull is by digest, so this mostly asserts the obvious - but it also
# asserts the image exists locally under exactly the reference the Compose file
# will use, with pull_policy: never.
if ! docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' \
	"${VAULTWARDEN_IMAGE}" | grep -qFx -e "${repository#docker.io/}@${digest}" -e "${repository}@${digest}"; then
	echo "> the pulled image does not carry digest ${digest}"
	docker image inspect --format '{{json .RepoDigests}}' "${VAULTWARDEN_IMAGE}" || true
	exit 1
fi
docker image inspect --format '> image {{.Id}} created {{.Created}}' "${VAULTWARDEN_IMAGE}"
echo '> Docker ready.'
