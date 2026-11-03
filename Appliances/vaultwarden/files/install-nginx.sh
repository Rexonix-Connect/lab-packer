#!/bin/bash
# nginx in front of Vaultwarden: TLS termination, the WebSocket upgrade, the
# admin allowlist, redacted access logs and an HTTP redirect. Everything
# deployment specific is a snippet the first-boot bootstrap rewrites.
set -euo pipefail

echo '> Installing the nginx site ...'
install -d -m 0755 /etc/nginx/snippets
install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/vaultwarden.conf" \
	/etc/nginx/sites-available/vaultwarden
for snippet in vaultwarden-proxy vaultwarden-server-name vaultwarden-admin vaultwarden-hsts; do
	install -m 0644 -o root -g root "${PAYLOAD_DIR}/nginx/${snippet}.conf" \
		"/etc/nginx/snippets/${snippet}.conf"
done
ln -sfn /etc/nginx/sites-available/vaultwarden /etc/nginx/sites-enabled/vaultwarden
rm -f /etc/nginx/sites-enabled/default

echo '> Generating a placeholder TLS certificate for the build ...'
# nginx refuses to start without one, and the build has to prove the stack
# serves HTTPS. finalize.sh deletes it; every deployment generates its own.
# /etc/vaultwarden is 0751: nginx's root master only has to traverse to tls/,
# and nothing else in it is readable by other accounts.
install -d -m 0751 -o root -g root /etc/vaultwarden
install -d -m 0755 -o root -g root /etc/vaultwarden/tls
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 \
	-days 1 -nodes \
	-keyout /etc/vaultwarden/tls/vaultwarden.key \
	-out /etc/vaultwarden/tls/vaultwarden.crt \
	-subj '/CN=vaultwarden-appliance-build' \
	-addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2>/dev/null
# nginx's master process reads the key as root; the workers never need it.
chown root:root /etc/vaultwarden/tls/vaultwarden.key
chmod 0600 /etc/vaultwarden/tls/vaultwarden.key

nginx -t
systemctl enable nginx.service
# The package started nginx with the stock site; nginx -t only validates the
# files on disk, so restart and assert the listener, as the NetBox build does.
systemctl restart nginx.service
if [ -z "$(ss -H -ltn 'sport = :443')" ]; then
	echo '> nginx is not listening on 443 after restart'
	systemctl --no-pager --full status nginx.service || true
	exit 1
fi

# No ufw rule here. The first-boot bootstrap opens 80/443 from the deploy
# form's vaultwarden.https-allow (anywhere when it is empty), so the template
# itself ships with only the base image's SSH rule.
echo '> nginx configured.'
