#!/bin/bash
# Operating system packages for the NetBox appliance: PostgreSQL, Redis, nginx
# and the toolchain NetBox's Python dependencies compile against.
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
	build-essential \
	fail2ban \
	git \
	libffi-dev \
	libpq-dev \
	libssl-dev \
	libxml2-dev \
	libxslt1-dev \
	nginx \
	postgresql \
	postgresql-client \
	prometheus-node-exporter \
	python3-dev \
	python3-venv \
	redis-server \
	ssl-cert \
	zlib1g-dev

echo '> Verifying dependency versions against the NetBox requirements ...'
# NetBox 4.6 needs Python 3.12+, PostgreSQL 14+ and Redis 5+; 4.7 raises the
# floors to PostgreSQL 15+ and Redis 6+. Ubuntu 24.04 satisfies all of them, so
# assert it rather than discover a regression after an image rebuild.
python3 - <<'PY'
import sys
if sys.version_info < (3, 12):
    sys.exit("python3 %d.%d is below the NetBox minimum of 3.12"
             % sys.version_info[:2])
print("> python3 %d.%d" % sys.version_info[:2])
PY

pg_major="$(psql --version | awk '{print $3}' | cut -d. -f1)"
if [ "${pg_major}" -lt 15 ]; then
	echo "> PostgreSQL ${pg_major} is below 15, which NetBox v4.7 requires"
	exit 1
fi
echo "> PostgreSQL ${pg_major}"

redis_major="$(redis-server --version | sed -n 's/.*v=\([0-9]*\).*/\1/p')"
if [ "${redis_major}" -lt 6 ]; then
	echo "> Redis ${redis_major} is below 6, which NetBox v4.7 requires"
	exit 1
fi
echo "> Redis ${redis_major}"

echo '> Configuring Redis for the NetBox task queue ...'
# The tasks database holds queued background jobs; evicting keys under memory
# pressure would silently drop them, so pin the policy. Both databases stay on
# loopback, which is where the stock Ubuntu configuration already binds.
install -d -m 0755 /etc/redis/redis.conf.d
cat >/etc/redis/redis.conf.d/10-netbox.conf <<'EOF'
# NetBox queues background jobs in Redis database 0; never evict them.
maxmemory-policy noeviction
EOF
if ! grep -q '^include /etc/redis/redis.conf.d/10-netbox.conf' /etc/redis/redis.conf; then
	printf '\ninclude /etc/redis/redis.conf.d/10-netbox.conf\n' >>/etc/redis/redis.conf
fi
systemctl restart redis-server
redis-cli ping | grep -qx PONG
[ "$(redis-cli config get maxmemory-policy | tail -n 1)" = 'noeviction' ]
echo '> Redis ready.'
