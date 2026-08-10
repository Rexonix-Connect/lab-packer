#!/bin/bash
# nginx in front of gunicorn: TLS termination, static files, the metrics
# allowlist, and an HTTP redirect. Everything deployment specific (server name,
# certificate, whether HSTS is sent, who may scrape metrics) is a small
# snippet the first-boot bootstrap rewrites; the site file itself is static.
set -euo pipefail

echo '> Installing the nginx site ...'
install -d -m 0755 /etc/nginx/snippets
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/netbox.conf" \
	/etc/nginx/sites-available/netbox
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/netbox-server-name.conf" \
	/etc/nginx/snippets/netbox-server-name.conf
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/netbox-metrics.conf" \
	/etc/nginx/snippets/netbox-metrics.conf
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/netbox-hsts.conf" \
	/etc/nginx/snippets/netbox-hsts.conf
ln -sfn /etc/nginx/sites-available/netbox /etc/nginx/sites-enabled/netbox
rm -f /etc/nginx/sites-enabled/default

echo '> Generating a placeholder TLS certificate for the build ...'
# nginx refuses to start without a certificate, and the build has to prove the
# whole stack serves HTTPS. This pair is deleted by finalize.sh; every
# deployment gets its own from netbox-firstboot.py.
install -d -m 0755 -o root -g root /etc/netbox/tls
openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
	-keyout /etc/netbox/tls/netbox.key \
	-out /etc/netbox/tls/netbox.crt \
	-subj '/CN=netbox-appliance-build' \
	-addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>/dev/null
chown root:www-data /etc/netbox/tls/netbox.key
chmod 0640 /etc/netbox/tls/netbox.key
chmod 0644 /etc/netbox/tls/netbox.crt

nginx -t
systemctl enable nginx.service

echo '> Opening the web ports in the firewall ...'
# The hardened base defaults to deny-incoming and only allows SSH. PostgreSQL,
# Redis and the node exporter stay on loopback and get no rule.
ufw allow 80/tcp
ufw allow 443/tcp
ufw status verbose
echo '> nginx configured.'
