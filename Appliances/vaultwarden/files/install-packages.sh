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
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o APT::Get::Always-Include-Phased-Updates=true)

echo '> Updating package lists (the base template ships with them cleaned) ...'
apt-get "${APT_OPTS[@]}" update

echo '> Applying pending security updates ...'
apt-get "${APT_OPTS[@]}" upgrade --yes

echo '> Installing appliance packages ...'
# argon2 hashes the Vaultwarden admin token at first boot.
apt-get "${APT_OPTS[@]}" install --yes --no-install-recommends \
	argon2 \
	ca-certificates \
	curl \
	docker-compose-v2 \
	docker.io \
	fail2ban \
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
