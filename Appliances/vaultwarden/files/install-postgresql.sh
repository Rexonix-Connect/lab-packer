#!/bin/bash
# The local PostgreSQL cluster, on the data disk, reachable only over its Unix
# socket.
#
# Vaultwarden connects as the vaultwarden OS account through the socket, which
# is bind-mounted into the container, and PostgreSQL authenticates it by peer:
# the kernel tells the server which uid is on the other end of the socket. So
# the appliance has no database password at all - nothing to generate, inject,
# rotate or leak - and the cluster listens on no TCP port whatsoever.
#
# The vaultwarden role and database are NOT created here. The template ships
# an empty cluster; the first-boot bootstrap creates the database, so a
# template can never carry anyone's schema or data.
set -euo pipefail

DATA_ROOT=/srv/vaultwarden
findmnt --noheadings --mountpoint "${DATA_ROOT}" >/dev/null

echo '> Creating the vaultwarden service account ...'
# A system account on the host, whose uid the container runs as. Peer
# authentication resolves that uid on the host side, so the name matches the
# database role without any pg_ident mapping.
if ! id vaultwarden >/dev/null 2>&1; then
	adduser --system --group --no-create-home --home /nonexistent vaultwarden
fi

pg_version="$(pg_lsclusters -h | awk 'NR==1{print $1}')"
pg_cluster="$(pg_lsclusters -h | awk 'NR==1{print $2}')"
pg_conf_dir="/etc/postgresql/${pg_version}/${pg_cluster}"
pg_data="${DATA_ROOT}/postgresql/${pg_version}/${pg_cluster}"

if [ "$(pg_lsclusters -h | awk 'NR==1{print $6}')" != "${pg_data}" ]; then
	echo "> Recreating cluster ${pg_version}/${pg_cluster} at ${pg_data} ..."
	install -d -m 0755 -o postgres -g postgres "${DATA_ROOT}/postgresql"
	pg_dropcluster --stop "${pg_version}" "${pg_cluster}"
	# Data checksums catch silent storage corruption at read time rather than
	# in a restore test months later. Encoding and locale are pinned rather
	# than inherited from whatever the base image's locale happens to be.
	pg_createcluster --locale=C.UTF-8 --encoding=UTF8 \
		--datadir="${pg_data}" "${pg_version}" "${pg_cluster}" -- --data-checksums
fi

echo '> Configuring PostgreSQL ...'
install -d -m 0755 -o postgres -g postgres "${pg_conf_dir}/conf.d"
cat >"${pg_conf_dir}/conf.d/10-vaultwarden.conf" <<'EOF'
# lab-packer Vaultwarden appliance.
#
# No TCP listener at all: Vaultwarden reaches the cluster through the Unix
# socket bind-mounted into its container, and nothing else needs it.
listen_addresses = ''
max_connections = 50
# Never log statement text. Vault items are end-to-end encrypted, but TOTP
# seeds, device push tokens and the like are plaintext columns, and the stock
# log_min_error_statement = error would write a failing statement in full
# (a constraint violation, a full disk, a deadlock). Vaultwarden's own log
# carries the error without the statement.
log_connections = off
log_disconnections = off
log_min_duration_statement = -1
log_min_error_statement = panic
log_statement = 'none'
log_line_prefix = '%m [%p] %q%u@%d '
EOF
chown postgres:postgres "${pg_conf_dir}/conf.d/10-vaultwarden.conf"
if ! grep -qE "^include_dir = 'conf.d'" "${pg_conf_dir}/postgresql.conf"; then
	echo "include_dir = 'conf.d'" >>"${pg_conf_dir}/postgresql.conf"
fi

# Only the socket rules remain: the host lines would be inert without a TCP
# listener, but a configuration that says what it means is easier to audit.
# First match wins, so the vaultwarden rule goes first.
cat >"${pg_conf_dir}/pg_hba.conf" <<'EOF'
# lab-packer Vaultwarden appliance: Unix socket only, peer authentication.
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   vaultwarden     vaultwarden                             peer
EOF
chown postgres:postgres "${pg_conf_dir}/pg_hba.conf"
chmod 0640 "${pg_conf_dir}/pg_hba.conf"

systemctl enable "postgresql@${pg_version}-${pg_cluster}.service"
systemctl restart "postgresql@${pg_version}-${pg_cluster}.service"
[ "$(pg_lsclusters -h | awk 'NR==1{print $6}')" = "${pg_data}" ]
[ "$(runuser -u postgres -- psql -tAc 'SHOW data_checksums')" = 'on' ]

if ss -H -ltn | grep -q ':5432 '; then
	echo '> PostgreSQL is listening on TCP; it must be socket-only'
	ss -ltnp
	exit 1
fi
echo "> PostgreSQL ${pg_version}/${pg_cluster} at ${pg_data}, socket only."
