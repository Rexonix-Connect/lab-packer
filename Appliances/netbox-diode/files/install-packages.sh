#!/bin/bash
# Operating system packages for the NetBox Diode appliance.
#
# Unlike the NetBox appliance, which installs its own PostgreSQL, Redis and
# Python stack, everything Diode needs ships inside its container images. What
# the host provides is only: a container runtime (added by install-docker.sh
# from Docker's own repository), nginx to terminate TLS in front of it, and the
# handful of tools the operator CLIs use.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# The base image runs unattended-upgrades, which is very likely to hold the
# dpkg lock on a freshly booted clone; wait for it instead of racing it.
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o APT::Get::Always-Include-Phased-Updates=true)

echo '> Updating package lists (the base template ships with them cleaned) ...'
apt-get "${APT_OPTS[@]}" update

echo '> Applying pending security updates ...'
apt-get "${APT_OPTS[@]}" upgrade --yes

echo '> Installing appliance packages ...'
apt-get "${APT_OPTS[@]}" install --yes \
	ca-certificates \
	curl \
	fail2ban \
	gnupg \
	jq \
	nginx \
	prometheus-node-exporter \
	ssl-cert

# jq is not a convenience here: the upstream OAuth2 client bootstrap script
# parses client-credentials.json with it, and diode-status reads the compose
# project's JSON output the same way.
command -v jq >/dev/null
echo '> Packages installed.'
