#!/bin/bash
# Operating system packages for the Vaultwarden appliance.
#
# PostgreSQL and nginx run natively, from the Ubuntu archive, exactly as on the
# NetBox appliance: unattended-upgrades patches them with the rest of the OS.
# Only Vaultwarden itself runs in a container, because that is how upstream
# ships it. Docker comes from the Ubuntu archive too (docker.io and
# docker-compose-v2) rather than a third-party repository, so it is signed by a
# key the base already trusts and is patched by the same unattended-upgrades
# run, with no extra apt source to keep in step.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# The base image runs unattended-upgrades, which is very likely to hold the
# dpkg lock on a freshly booted clone; wait for it instead of racing it.
#
# confdef/confold: the hardened base modifies conffiles that packages later
# ship new versions of - /etc/issue.net (its SSH pre-auth banner) came with
# base-files 13ubuntu10.5 - and DEBIAN_FRONTEND=noninteractive does not cover
# dpkg's own conffile prompt, which then dies with "end of file on stdin".
# Keeping the installed version is also what the base's own
# unattended-upgrades does, so a deployed appliance behaves the same way.
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o APT::Get::Always-Include-Phased-Updates=true
	-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo '> Updating package lists (the base template ships with them cleaned) ...'
apt-get "${APT_OPTS[@]}" update

echo '> Applying pending security updates ...'
apt-get "${APT_OPTS[@]}" upgrade --yes

echo '> Configuring the Docker daemon before it is installed ...'
# The package starts dockerd as soon as it is installed, and a daemon started
# with the defaults creates docker0, the DOCKER iptables chains and turns on
# ip_forward - state a later restart with a restrictive configuration does not
# undo. So the configuration goes in first, and the daemon's very first start
# is already the locked-down one. What it says, and why, is in
# install-docker.sh, which asserts it took effect.
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

echo '> Installing appliance packages ...'
# argon2 hashes the Vaultwarden admin token at first boot. libsecret-1-0 is
# the one native library the Bitwarden Directory Connector CLI loads
# (install-directory-connector.sh); the keyring behind it is not used.
apt-get "${APT_OPTS[@]}" install --yes --no-install-recommends \
	argon2 \
	ca-certificates \
	curl \
	docker-compose-v2 \
	docker.io \
	fail2ban \
	libsecret-1-0 \
	nginx \
	postgresql \
	postgresql-client \
	ssl-cert

echo '> Verifying dependency versions ...'
pg_major="$(psql --version | awk '{print $3}' | cut -d. -f1)"
if [ "${pg_major}" -lt 14 ]; then
	echo "> PostgreSQL ${pg_major} is older than anything Vaultwarden is tested against"
	exit 1
fi
echo "> PostgreSQL ${pg_major}"
echo "> $(docker --version)"
echo "> $(docker compose version)"
echo "> $(nginx -v 2>&1)"
command -v argon2 >/dev/null
echo '> Packages installed.'
