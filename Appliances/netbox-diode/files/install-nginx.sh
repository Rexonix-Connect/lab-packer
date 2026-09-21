#!/bin/bash
# Host nginx in front of the compose project: TLS termination on 443, an HTTP
# redirect, and the metrics allowlist.
#
# This is the only thing on the appliance the network can reach. The Diode
# ingress container publishes on 127.0.0.1 only, so the container runtime's
# firewall behaviour - Docker inserts rules ahead of ufw's chains - never gets
# the chance to matter. Everything deployment specific (server name,
# certificate, whether HSTS is sent, who may scrape metrics) is a small
# snippet diode-firstboot.py rewrites; the site file itself is static.
set -euo pipefail

echo '> Installing the nginx site ...'
install -d -m 0755 /etc/nginx/snippets
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/diode.conf" \
	/etc/nginx/sites-available/diode
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/diode-server-name.conf" \
	/etc/nginx/snippets/diode-server-name.conf
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/diode-metrics.conf" \
	/etc/nginx/snippets/diode-metrics.conf
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/diode-hsts.conf" \
	/etc/nginx/snippets/diode-hsts.conf
ln -sfn /etc/nginx/sites-available/diode /etc/nginx/sites-enabled/diode
rm -f /etc/nginx/sites-enabled/default

echo '> Generating a placeholder TLS certificate for the build ...'
# nginx refuses to start without a certificate, and the build has to prove the
# whole stack serves. This pair is deleted by finalize.sh; every deployment
# gets its own from diode-firstboot.py.
install -d -m 0755 -o root -g root /etc/diode/tls
openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
	-keyout /etc/diode/tls/diode.key \
	-out /etc/diode/tls/diode.crt \
	-subj '/CN=netbox-diode-appliance-build' \
	-addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>/dev/null
chown root:www-data /etc/diode/tls/diode.key
chmod 0640 /etc/diode/tls/diode.key
chmod 0644 /etc/diode/tls/diode.crt

nginx -t
systemctl enable nginx.service
# The package started nginx with the stock configuration when it was
# installed, and `nginx -t` only validates the files on disk - it says nothing
# about what the running process is serving. Without this restart the daemon
# keeps the default site and never binds 443.
systemctl restart nginx.service
if [ -z "$(ss -H -ltn 'sport = :443')" ]; then
	echo '> nginx is not listening on 443 after restart'
	systemctl --no-pager --full status nginx.service || true
	exit 1
fi

echo '> Opening the web ports in the firewall ...'
# The hardened base defaults to deny-incoming and only allows SSH. The Diode
# ingress, Hydra, PostgreSQL, Redis and the node exporter are all on loopback
# and get no rule.
ufw allow 80/tcp
ufw allow 443/tcp
ufw status verbose
echo '> nginx configured.'
