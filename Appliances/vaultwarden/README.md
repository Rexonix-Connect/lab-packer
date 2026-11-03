# Vaultwarden appliance

A [Vaultwarden](https://github.com/dani-garcia/vaultwarden) password manager on one hardened Ubuntu 24.04 VM, deployable from the vSphere content library and serving HTTPS a minute or two after power-on. Built the same way as the NetBox appliance next to it: cloned from the hardened 24.04 library item, configured through the vApp deploy form, bootstrapped on first boot.

This file is the operator handbook: architecture, deployment, first setup, security model, backup and recovery, upgrades and the test plan. The build workflow itself is summarized in the [repository README](../../README.md#build-vaultwarden-appliance-vm-template).

- [Architecture](#architecture)
- [Building the template](#building-the-template)
- [Deploying](#deploying)
- [First setup: administrator, organization, users](#first-setup-administrator-organization-users)
- [Security model](#security-model)
- [Day-two operations](#day-two-operations)
- [Backup and restore](#backup-and-restore)
- [Disaster recovery](#disaster-recovery)
- [Updates](#updates)
- [Test plan](#test-plan)
- [Known limitations](#known-limitations)

## Architecture

```text
   clients (browser, extension, desktop, mobile, CLI)
                    |  HTTPS 443  (80 only redirects)
          ufw: vaultwarden.https-allow
                    |
   +----------------+--------------------------------------------+
   |  nginx (Ubuntu package)                                     |
   |   TLS, WebSocket upgrade, /admin allowlist, redacted logs   |
   |                 |  http://127.0.0.1:8000                    |
   |  Vaultwarden 1.37.5 (official image, pinned by digest)      |
   |   Docker, host network, loopback bind, read-only rootfs,    |
   |   all capabilities dropped, runs as uid "vaultwarden"       |
   |                 |  Unix socket /run/postgresql, peer auth   |
   |  PostgreSQL 16 (Ubuntu package), no TCP listener at all     |
   +-------------------------------------------------------------+
     disk 1  /                 hardened Ubuntu 24.04, Docker image
     disk 2  /srv/vaultwarden  postgresql/  data/  backups/
```

Why it is shaped this way:

- **PostgreSQL and nginx are native packages, only Vaultwarden is a container.** That is how upstream ships Vaultwarden, while the two components with the largest CVE history are patched by `unattended-upgrades` with the rest of the OS, exactly as on the NetBox appliance, instead of waiting for someone to bump an image digest. Ubuntu 24.04 ships PostgreSQL **16** (supported to November 2028); Vaultwarden supports it fully, so the brief's "17 if compatible" was traded for archive patching. A PGDG 17 would be a third-party repository to maintain.
- **Docker cannot open the firewall.** `iptables` and `ip6tables` management are off and there is no default bridge, so the daemon writes no netfilter rule at all; the container uses the host network and binds `127.0.0.1:8000`, so there is no published port to forward around ufw in the first place. ufw remains the single authority over what is reachable. The build fails if any Docker chain, `docker0`, a TCP Docker API or a non-loopback listener other than 22/80/443 exists.
- **There is no database password.** PostgreSQL listens on no TCP port; the socket directory is bind-mounted into the container, and peer authentication lets the kernel vouch for the `vaultwarden` uid the container runs as. Nothing to generate, inject, rotate or leak.
- **Exactly one Vaultwarden instance.** One container, owned by one systemd unit (`vaultwarden.service`, `Restart=always`), with a Docker restart policy of `no` so dockerd never starts it on its own. No replicas, no failover, no shared filesystem.
- **Data on its own disk.** The database, attachments, Sends, the RSA signing key and the local backups live on disk 2. The root disk can be lost and rebuilt from the template; disk 2 is the appliance.

### Never an empty instance by accident

Vaultwarden happily creates a fresh schema and a fresh signing key on any empty database and directory it is pointed at. On a password manager that failure mode looks like *everyone's vault is gone* and the first login re-registers over the top. Four independent things prevent it:

1. The `/srv/vaultwarden` mount point on the root disk is **immutable** (`chattr +i`). Without the disk mounted, nothing - not `initdb`, not Vaultwarden, not root - can write there.
2. `RequiresMountsFor=/srv/vaultwarden` on PostgreSQL, the bootstrap, Vaultwarden and the backup. The fstab entry is `nofail`, so a missing disk leaves the VM bootable and reachable on the console, with the services visibly down.
3. **`vaultwarden-guard`** runs before every start. It refuses unless the disk is mounted, carries the **volume id** this deployment recorded (`/srv/vaultwarden/.volume-id` must equal `/etc/vaultwarden/volume-id`), and - once the deployment has been initialized - the database still has Vaultwarden's schema and `rsa_key.pem` still exists. A blank, foreign or emptied disk is a refusal with a message, never a new instance.
4. The bind mounts use `create_host_path: false`, so a missing directory is an error rather than an empty new one.

A refused start retries five times in ten minutes and then stays failed, so it shows up in `systemctl --failed`, `vaultwarden-status` and monitoring instead of looping quietly.

## Building the template

Run **Build Vaultwarden Appliance VM Template** from the Actions tab. It needs the hardened 24.04 template in the content library (it is cloned from it), the same vCenter variables and secrets as the other builds, and one new repository variable:

- `VAULTWARDEN_APPLIANCE_X64_VM_TEMPLATE_NAME` - the library item to create, e.g. `VAULTWARDEN_APPLIANCE_x64_VM`

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `vaultwarden_version` | `1.37.5` | `X.Y.Z` only; `latest` is rejected by the Packer variable validation |
| `vaultwarden_image_digest` | `sha256:4fe17f41…` | The multi-arch index digest for that version. Change both together |
| `cpu_count` / `memory_mb` | `2` / `8192` | Comfortable for a few hundred users; both can be changed at deploy time |
| `data_disk_gb` | `100` | Thin. Grow later in vCenter; the filesystem follows on the next boot |
| `firmware` | `efi-secure` | Must match the hardened base |
| `ssh_timeout` | `45m` | |

The workflow has a `check` job that needs no vCenter (bootstrap logic tests, guard tests, `bash -n` on every script, the deploy-form composition, `packer fmt -check` and `packer validate`), and only then the `packer` job that builds. No new secrets: the build introduces none.

**What the build proves before it exports** (`files/verify.sh`), on the real VM: the web vault is served through nginx; `/alive` answers; registration is refused for an address nobody invited (a real request, not the `/api/config` flag, which is legitimately `false` while invitations are on and mail is off); plain HTTP redirects; `/admin` from a non-loopback address is a 403 from nginx, and from loopback the token read from the secret file logs in; the access log contains no query string; ufw is active; only 22/80/443 listen off loopback, Vaultwarden is on `127.0.0.1:8000`, PostgreSQL has no TCP listener, no container publishes a port, Docker wrote no netfilter rule; no secret is in the container environment; the container root is read-only and runs as the `vaultwarden` uid; PostgreSQL's data directory is on disk 2 with checksums on; the mount point underneath is immutable; the guard refuses a foreign volume id; a `docker kill` is recovered by systemd; a `vaultwarden-backup` → `vaultwarden-restore` round-trip brings back the same signing key; the fail2ban jails run; no ordering cycle; and the whole hardened baseline (module blocks, sysctls, auditd, `recovery`, `ovf-settings`, lockdown) still holds with Docker installed. Then it drops the database and empties the data disk.

**What ships in the template:** the OS packages, the Docker engine, the Vaultwarden image (pulled by digest - an air-gapped site never needs Docker Hub), an *empty* PostgreSQL cluster, the configuration and the tooling. **What does not:** any database, schema or user data, the RSA signing key, an admin token, TLS key, SMTP or SSO secret, FQDN or address, volume id, SSH host keys, machine id, or the build account.

Manual equivalents of the static checks, from the repository root:

```bash
python3 Appliances/vaultwarden/tests/test_firstboot.py
bash Appliances/vaultwarden/tests/test_guard.sh
packer init shared/config.pkr.hcl && packer fmt -check Appliances/vaultwarden
```

## Deploying

Deploy from the content library like any other template. Size it in the wizard if needed (CPU, memory, disk 2). Then fill the **Customize template** page: the shared Guest Identity / Guest Network fields first (hostname, your admin user and SSH key, static address), then the Vaultwarden categories. **Every Vaultwarden field is optional** - an empty form produces a working appliance with a self-signed certificate - but for real use you will want at least the FQDN, a trusted certificate, SMTP, the allowlists and an organization creator.

| Property | Meaning |
| --- | --- |
| `vaultwarden.fqdn` | The name users browse to. Becomes `DOMAIN`, nginx's `server_name` and the certificate name. **It is also the WebAuthn/FIDO2 relying-party id: changing it after users registered security keys invalidates those keys.** Pick it once |
| `vaultwarden.time-zone` | IANA zone, e.g. `Europe/Prague`; default `UTC` |
| `vaultwarden.org-creators` | Emails allowed to create organizations (`ORG_CREATION_USERS`). Empty means **nobody** - set it to the first administrator's address |
| `vaultwarden.admin-allow` | CIDRs allowed to reach `/admin` (management/VPN). Empty = loopback only, i.e. an SSH tunnel |
| `vaultwarden.admin-token-hash` | Optional argon2id PHC hash of an admin token you hold (`vaultwarden-admin-token hash`). Empty generates one |
| `vaultwarden.https-allow` | CIDRs allowed to reach 443 (and the 80 redirect) through ufw. Empty = any source |
| `vaultwarden.ssh-allow` | Management CIDRs allowed to SSH. Empty keeps the base image's any-source rule |
| `vaultwarden.proxy` / `no-proxy` | Outbound proxy for apt, image pulls, icons, push and the OIDC provider. **Unauthenticated only** (`http://host:port`): a credential would land in `/etc/environment` and the container environment, readable by every local account, so a URL with `user:password@` is refused |
| `vaultwarden.tls-cert` / `tls-key` | Base64 PEM chain (leaf first) and key. Mismatch fails the bootstrap on purpose |
| `vaultwarden.smtp-host` / `-port` / `-security` / `-from` / `-username` / `-password` | Mail relay. Without it nothing is mailed and email verification is not enforced (it would lock invited users out) |
| `vaultwarden.sso-authority` / `-client-id` / `-client-secret` | Optional OpenID Connect (Entra ID, Keycloak). Off unless **all three** are set - Vaultwarden refuses to start with SSO enabled and no secret, so an incomplete set means SSO off, not an appliance down. Never SSO-only |
| `vaultwarden.sso-scopes` | Default `openid profile email offline_access`; `offline_access` is what yields a refresh token |
| `vaultwarden.sso-signups-allowed` | `true` lets a first SSO login create an account for anyone the IdP authenticates; default `false` = invite first |
| `vaultwarden.sso-allow-unknown-email-verification` | `true` is **required for Entra ID**, which sends no `email_verified` claim; see [SSO with Entra ID](#sso-with-microsoft-entra-id) for why it is otherwise off |

> **vApp properties are not a secret store.** They sit in the VM configuration in cleartext for anyone with read access to the VM in vCenter; `type="password"` only masks the wizard field. The bootstrap copies secret fields into root-only files, and **an empty secret field never clears a stored secret** - so after the first boot, clear `tls-key`, `smtp-password` and `sso-client-secret` in **Edit Settings → vApp Options**. Better still, install the certificate afterwards with `vaultwarden-tls install`.

### First boot

`vaultwarden-bootstrap.service` runs once: it adopts or creates the data-disk volume id, creates the `vaultwarden` role and database, generates the admin token (hash only on disk), renders `/etc/vaultwarden/vaultwarden.env` from the form, issues or installs the certificate, writes the nginx snippets, opens ufw from the allowlists and applies the proxy. Then `vaultwarden.service` starts the container, Vaultwarden creates its schema and RSA key, and the guard marks the deployment **initialized** - from then on an empty database or a missing key is a refusal.

The generated admin token is printed **once** on the VM console (`/etc/issue.d`, never the SSH banner) and written to `/root/vaultwarden-credentials.txt`. Store it in your break-glass store and run `vaultwarden-credentials --clear`.

On every later boot `vaultwarden-reconcile.service` re-reads the form and re-applies configuration - name, settings, allowlists, firewall, proxy, a self-signed certificate - so changing a property is: edit it in vCenter, then **power off and on** (a guest reboot does not refresh the OVF environment). It never generates a secret or touches data. A failed bootstrap leaves the appliance visibly down with the traceback in `/var/lib/vaultwarden-appliance/failed`; fix and `systemctl start vaultwarden-bootstrap`.

### Certificates and clients

Bitwarden's desktop, mobile and browser-extension clients **refuse untrusted certificates**, and there is no supported way to make them accept one - do not try. Use one of:

- a certificate from a public CA (DNS-01 validation works for an internal-only name), or
- a certificate from the company CA that every managed device already trusts at the OS level. On iOS a manually installed root also needs *Settings → General → About → Certificate Trust Settings → full trust*. Verify the mobile apps on your actual fleet before rollout.

Install at deploy time (`vaultwarden.tls-cert`/`tls-key`) or later with `vaultwarden-tls install fullchain.pem privkey.pem`, which refuses a mismatched pair, an expired certificate or a wrong-order chain, warns when no SAN covers the FQDN, and switches HSTS on. Renewal is the same command; `vaultwarden-tls show` reports expiry. No ACME client is installed: the appliance is assumed not to be reachable from the internet; renew from wherever your DNS-01 automation runs.

## First setup: administrator, organization, users

1. **Reach the admin page.** From a network in `vaultwarden.admin-allow`, or with `ssh -L 8443:127.0.0.1:443 admin@vault` and a hosts-file entry mapping the FQDN to 127.0.0.1 (so the Host matches `DOMAIN`), open `https://<fqdn>:8443/admin` and enter the admin token.
2. **Check the diagnostics page** in `/admin`: time, domain, database type (PostgreSQL), and that the web vault version is recent.
3. **Send a test email** from `/admin` → *Settings → SMTP Email Settings → Send test email* if SMTP is configured.
4. **Invite the first administrator** (*Users → Invite User*). With SMTP they get an email; without it they open the web vault and *Create account* with the invited address - signups are closed to everyone else.
5. The administrator signs in, **enables two-step login** (prefer a FIDO2/WebAuthn security key; TOTP as a second method) and creates the **organization** - which works only because their address is in `vaultwarden.org-creators`.
6. In the organization: create **collections** per team or system, then under *Policies* enable **Require two-step login** (members without 2FA lose access to the organization until they enable it), **Master password requirements**, and optionally **Single organization** and **Remove individual vault** if company data must live only in the organization. Invite members, assign **roles** (Owner, Admin, Manager, User) and collection access. Upstream ships **groups** off (`ORG_GROUPS_ENABLED`, marked beta); if you want them to map teams, enable the setting in `/admin` and test, knowing it then lives in `config.json`.
7. Leave `/admin` closed afterwards: empty `vaultwarden.admin-allow` and power-cycle, or disable the token entirely with `vaultwarden-admin-token disable` (re-enable with `rotate`).

**Offboarding an employee:** in the organization, *Members → Revoke* immediately removes access to organization items (the 1.37.4 advisories that let revoked members keep read access are fixed in this version); then *Remove*. In `/admin` → *Users*, **deauthorize sessions** and **disable** or delete the account. Two things no server can undo: anything the person already synced is in their clients' local, encrypted cache until those clients sync again or are wiped, and anything they saw they may have copied. **Rotate the credentials they had access to** - that is the actual revocation.

### SSO with Microsoft Entra ID

Off by default, prepared for later. What SSO does and does not do in Vaultwarden, before anything else: it replaces the *login* step only. Users still need their master password to decrypt their vault (it never leaves the device, so nothing in Entra can unlock a vault), Vaultwarden's own **two-step login is still enforced after the SSO step** (confirmed in the 1.37.5 source), disabling a user in Entra does not revoke a session Vaultwarden already issued (deauthorize them in `/admin` too), and local login stays available (`SSO_ONLY=false`) so an Entra outage does not lock everyone out of their passwords.

1. **Entra ID:** *App registrations → New registration*, single tenant. Under *Authentication* add a **Web** redirect URI `https://<fqdn>/identity/connect/oidc-signin` (it is derived from `vaultwarden.fqdn`; they must match exactly). Under *Certificates & secrets* create a client secret - note its expiry, it has to be rotated. Under *API permissions* grant `openid`, `profile`, `email`, `offline_access` (delegated; `offline_access` is what returns a refresh token). Take the **Directory (tenant) ID** and the **Application (client) ID** from the overview. In the matching *Enterprise application*, set **Assignment required = Yes** and assign the group of employees who may use Vaultwarden - that is where "who gets an account" is decided.
2. **Deploy form** (*Edit Settings → vApp Options*, then power off and on):
   - `vaultwarden.sso-authority` = `https://login.microsoftonline.com/<tenant id>/v2.0` (v2 only; v1 is not OIDC-compliant)
   - `vaultwarden.sso-client-id` = the Application ID, `vaultwarden.sso-client-secret` = the secret value (clear the field after the boot; the stored copy stays)
   - `vaultwarden.sso-scopes` = leave empty (`openid profile email offline_access`); upstream's example uses `User.Read` instead of `email`, either works
   - `vaultwarden.sso-allow-unknown-email-verification` = `true`. **Entra ID sends no `email_verified` claim**, and Vaultwarden then refuses every SSO login outright (*"Your provider does not send email verification status"*). Upstream warns that accepting an unknown status together with `SSO_SIGNUPS_MATCH_EMAIL` (on, so people invited before SSO keep their vault) can let an IdP account take over an existing local account with the same address. With Entra ID that address is the company's own UPN/mail, which users cannot set themselves, so the risk is the tenant's integrity - acceptable; it would not be with a social or self-service IdP.
   - `vaultwarden.sso-signups-allowed` = `true` once assignment is enforced at Entra, so an assigned employee's first SSO login creates their account; leave it `false` to keep invite-first.
3. **Clients:** on the login screen, *Log in with SSO*; the "organization identifier" Bitwarden clients ask for is not used by Vaultwarden - any value works. Test the web vault, the browser extension, a desktop and a mobile client; upstream notes browser-redirect quirks on Linux/Windows desktop clients.
4. **Operations:** `vaultwarden-status` shows `SSO OpenID Connect enabled`; the SSO client is not subject to `HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS` (a Keycloak on an RFC1918 address works too, verified in the source); the provider is reached through `vaultwarden.proxy` when one is set; a private CA on the provider needs its root in the container's trust store (`SSL_CERT_FILE`), which this image does not wire up - Entra's public CA needs nothing. Changing the authority URL later orphans the `sso_users` links (upstream documents a `TRUNCATE`); back up first.

## Security model

| Control | Where |
| --- | --- |
| Hardened baseline (Secure Boot, lockdown, module blocks, sysctls, auditd, SSH crypto, `/dev/shm` noexec, unattended-upgrades) | Inherited from the hardened template, re-verified by the build |
| Inbound: 443/80 from `https-allow`, 22 from `ssh-allow` (or the base rule), nothing else | ufw, owned by the bootstrap; rules carry the comment `vaultwarden-https`/`vaultwarden-ssh` |
| Docker cannot bypass ufw | `iptables:false`, `ip6tables:false`, `bridge:none`, host network, loopback bind |
| Admin page | nginx allowlist (loopback + `admin-allow`), argon2id token, `ADMIN_RATELIMIT` 3 per 5 min, 20-minute sessions, fail2ban (3 tries → 6 h) |
| Login brute force | `LOGIN_RATELIMIT` 10 burst / 60 s, fail2ban (10 tries → 1 h), both keyed on the real client address via `X-Real-IP` trusted from loopback only |
| Account creation | Invitation only; org creation restricted to `org-creators`; password hints off |
| SSRF via the icon fetcher | `HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS=true` |
| Container | Read-only root, `cap_drop: ALL`, `no-new-privileges`, non-root uid, pids limit, image pinned by digest, `pull_policy: never` |
| Database | No TCP listener, peer auth, data checksums, on its own disk |
| Secrets | Files under `/etc/vaultwarden/secrets` (`0440 root:vaultwarden`), bind-mounted read-only, read via `ADMIN_TOKEN_FILE` / `SMTP_PASSWORD_FILE` / `SSO_CLIENT_SECRET_FILE` |
| Logs | nginx access log without query strings or Referer; Vaultwarden at `LOG_LEVEL=warn`; PostgreSQL never logs statement text (`log_min_error_statement = panic`) |

**Secrets and environment variables.** Container environment variables are visible to anyone who can run `docker inspect` (root and the `docker` group, which is empty and asserted empty), in `/proc/<pid>/environ` to root, and in any crash or support dump that captures the environment. That is why the settings file holds **no secret** - the build asserts it - and every secret is a file read through Vaultwarden's `_FILE` support. The admin token is stored only as an argon2id hash. What is still plaintext on disk: the SMTP password and SSO client secret (Vaultwarden needs them in the clear to use them), each a root-only file, and the TLS key (`0600 root`; nginx's master process reads it as root). Backups contain all of these; they are `0600` in a `0700` directory. The proxy URL is the one setting that reaches both the container environment and the world-readable `/etc/environment`, which is why a proxy credential is refused rather than stored.

**Rotation:** admin token - `vaultwarden-admin-token rotate`. SMTP password / SSO secret - set the vApp field to the new value, power-cycle, then clear the field. TLS - `vaultwarden-tls install`. Database - there is no password to rotate. User master passwords and the encryption keys are the users' own.

**Logs.** The access log uses a `vaultwarden_redacted` format: path without query string, no Referer - the WebSocket hub's `access_token` and attachment/Send download tokens travel in query strings. The nginx **error log cannot be redacted** (nginx writes the original request line into upstream errors); it is `root:adm` readable and rotated with `/var/log/nginx` (14 days). Vaultwarden logs at `warn`, because at `info` it logs request lines; failed logins and bad admin tokens are logged at `error`, which is what fail2ban reads. Master passwords never reach the server at all - clients send a derived hash.

**Settings saved in `/admin` override the deploy form.** Vaultwarden writes them to `/srv/vaultwarden/data/config.json`, which takes precedence over environment variables, silently. `vaultwarden-status` says when that file exists. Prefer the deploy form; use `/admin` settings for things the form does not expose, and know that they then stick.

**Moving to a DMZ reverse proxy later.** Keep this appliance internal; put the external hardened proxy in front of 443, set `vaultwarden.https-allow` to the proxy's address, keep `/admin` off the proxy entirely (don't forward `/admin`), and add the proxy to Vaultwarden's trusted proxies so rate limits and fail2ban see real client addresses: `IP_HEADER_TRUSTED_PROXIES` is rendered as `local` today; changing it is a one-line change in `build_settings()` in `vaultwarden-firstboot.py` plus nginx `set_real_ip_from`. Not done now because nothing needs it yet.

## Day-two operations

All in `/usr/local/sbin`. `vaultwarden-status` runs as anyone; the rest require root and say so.

| Command | Purpose |
| --- | --- |
| `vaultwarden-status` | URL, TLS, SMTP, SSO, org creators, allowlists, service states, data-disk use (warns at 85 %), **whether it serves** (`/alive` through nginx), `config.json` override warning, patch state, last backup and its age. **Exit status is non-zero when not serving, a service is down, the data disk is unmounted or ufw is inactive** - point monitoring at it; patch state and backup age are text only. Drives the MOTD |
| `vaultwarden-backup` | Consistent backup pair into `/srv/vaultwarden/backups`, optional off-box copy |
| `vaultwarden-restore <stamp>` | Restore a pair; safety backup first; refuses newer-than-installed backups |
| `vaultwarden-upgrade <X.Y.Z> <sha256:…>` | Backup, pull by digest, restart, verify, record; prints the rollback |
| `vaultwarden-tls show` / `install <cert> <key>` | Certificate status and replacement |
| `vaultwarden-admin-token rotate` / `hash` / `disable` | Admin page token |
| `vaultwarden-credentials [--clear]` | The one plaintext copy of a generated token |
| `vaultwarden-guard pre-start` | Run by systemd; run by hand to see why Vaultwarden refuses to start |
| `vaultwarden-datadisk-grow` | Run at boot; grows `/srv/vaultwarden` after disk 2 was enlarged |

Never `docker compose up -d` by hand: it bypasses the guard. Use `systemctl restart vaultwarden`. Container output is the `vaultwarden.service` journal: `journalctl -u vaultwarden`.

### Monitoring integration points

No monitoring stack is installed on the appliance. What to scrape or poll:

| Signal | How |
| --- | --- |
| Application health, end to end | `https://<fqdn>/alive` → 200 (proves nginx, Vaultwarden and its database connection); or `vaultwarden-status` exit code over SSH |
| Functional synthetic check | `https://<fqdn>/api/config` returns JSON; a scheduled `bw login` + `bw sync` with a dedicated low-privilege test account proves login, decryption and sync - a 200 alone does not |
| Units | `vaultwarden`, `nginx`, `docker`, `postgresql@16-main`, `fail2ban`, `vaultwarden-backup.service` (its `Result`) |
| Disk | `/srv/vaultwarden` and `/` utilization |
| Backup | newest `/srv/vaultwarden/backups/*.dump` younger than 36 h; `vaultwarden-backup.service` result |
| TLS expiry | `openssl s_client` against 443, or `vaultwarden-tls show` |
| Security events | journal of `vaultwarden.service` (failed logins, bad admin tokens), `fail2ban-client status vaultwarden`, auditd, `sshd` |
| CPU / memory | vCenter performance charts |

Logs leave the box with whatever journal or syslog forwarder your environment uses; the appliance writes everything to the journal plus `/var/log/nginx`.

## Backup and restore

### Native application backups

`vaultwarden-backup.timer` runs nightly at 01:30 (±30 min), before a typical Veeam window, so the VM-level backup also carries a fresh application dump. Each run writes a pair to `/srv/vaultwarden/backups`:

- `vaultwarden-<stamp>.dump` - `pg_dump --format=custom`
- `vaultwarden-<stamp>.files.tar.gz` - the data directory (attachments, Sends, `rsa_key.pem`, `config.json`; not the icon cache), the secrets, the rendered settings, the image reference, and `backup-info` (host, volume id, image, PostgreSQL version)

By default (`QUIESCE=yes` in `/etc/default/vaultwarden-backup`) Vaultwarden is stopped for the seconds both take, so the database and the attachment files describe the same instant; a trap restarts it however the run ends, and a failed run deletes its partial files. Both halves are verified readable before the run counts. Retention: `RETENTION_DAYS=14`.

**A backup on the disk it protects is not a backup.** Set `OFFSITE_COMMAND` in `/etc/default/vaultwarden-backup` to a script that copies the pair to protected storage (it gets the two paths as arguments; a failure fails the unit). Treat the archives like the vault itself: they contain the RSA signing key and the secrets. User vault contents inside them are end-to-end encrypted with keys derived from master passwords, but metadata, organization structure, attachments' encryption and the server key are not something to leave on an open share. Upstream's advice applies: add your own encryption layer (`age`, `gpg`) in the off-site step, especially where the destination is cloud storage.

### Veeam

Configure a Veeam job for the VM with:

- **Both disks** included (disk 2 is where all data lives; excluding it backs up nothing of value).
- Guest processing: **application-aware processing on, with a Linux guest credential**. Here PostgreSQL runs *natively*, not in Docker, so Veeam's PostgreSQL processing can apply in principle - **verify it against your installed Veeam version** and configure it to use the `postgres` OS account (peer authentication; there is no database password). If it cannot be made to work, rely on crash consistency plus the nightly native dump, which the job captures either way; scheduling the job after 02:30 guarantees a dump less than an hour old.
- A repository with **immutability** (hardened Linux repository or object lock) and a retention that covers at least the native retention (14 days) plus your audit requirement.
- **Job-completion alerting**, and a periodic **SureBackup / restore test into an isolated network** - see the test plan.

vSphere HA, VM replication and database recovery are different things: **HA** restarts this VM on another host after a host failure (same disks, seconds to minutes, protects against hardware); **replication** (Veeam replica or vSphere Replication) keeps a powered-off copy elsewhere for site loss - only one copy may ever be powered on, because two Vaultwarden instances with diverging databases cannot be merged; **database recovery** (native dump or Veeam restore) is what protects against deletion, corruption or a bad upgrade, which HA and replication faithfully copy.

### Restore procedures

**A. Application restore on the same appliance** (deleted data, bad upgrade):

```bash
sudo vaultwarden-restore              # lists the backups
sudo vaultwarden-restore 20261103T013512Z
```

It asks you to type the host name, takes a safety backup, stops Vaultwarden, recreates the database from the dump, replaces the data directory and secrets, re-renders the settings, starts and checks `/alive`. It refuses a backup written by a newer Vaultwarden than the one installed (no schema downgrade) - upgrade first.

**B. Recovery onto a new VM with the same FQDN** (lost VM, new template version):

1. Make sure the old VM is **powered off** and stays off.
2. Deploy the template with the same `vaultwarden.fqdn`, certificate and settings (same IP or update DNS).
3. Copy the backup pair into `/srv/vaultwarden/backups/` on the new VM.
4. `sudo vaultwarden-restore <stamp>`.
5. Validate (below), then point users at it.

Because the FQDN is the same, WebAuthn keys keep working and clients only need to sign in again.

**C. Re-attaching the old data disk to a new VM:** attach the old disk 2 *instead of* the template's at SCSI 0:1 before first power-on. The disk is mounted by its filesystem label, so this works across template builds, not only within one. The bootstrap finds the disk's volume id, adopts it, keeps the existing database and marks the deployment initialized immediately; if the disk carries a signing key but its database has no schema, it refuses to start rather than create an empty instance (restore from a backup instead). If you attach it to an already bootstrapped appliance, the guard refuses (foreign volume id) and prints the explicit `cp` line to adopt it. Everything that lived on the *root* disk is gone and comes back from the template plus the deploy form: a **new admin token** is generated (the old one no longer works), and the TLS key, SMTP password and SSO secret must be supplied again through the form or `vaultwarden-tls install`. Users notice nothing: sessions, keys and vaults are all on disk 2.

**D. Full VM restore from Veeam:** restore both disks together, to an isolated network first if the original might still be running. Power on; the appliance comes up as it was at the restore point.

**Validate after any restore:** sign in with a known account, open several items, open an attachment, check an organization collection and its members, check a Send link, and confirm a client syncs. Confirm the restored instance is the *only* one running for that FQDN.

## Disaster recovery

| Event | Recovery | Data loss |
| --- | --- | --- |
| ESXi host failure | vSphere HA restarts the VM | None beyond in-flight requests |
| Guest OS broken, data disk fine | New VM from the template + procedure C | None |
| Data disk lost or corrupted | Veeam restore of the VM (D) or new VM + native backup (B) | Since the last backup |
| Bad Vaultwarden upgrade | `vaultwarden-restore` of the pre-upgrade backup with the previous image (printed by the upgrade) | Since the upgrade |
| Site loss | Replica or Veeam restore at the second site, DNS update | Replication / backup interval |
| Accidental deletion by a user | Users restore from Trash (kept until emptied - `TRASH_AUTO_DELETE_DAYS` is unset); otherwise restore to an *isolated* copy and export the item | — |

There is deliberately no automatic failover. A powered-off standby (Veeam replica) can be added later; promoting it is a manual decision precisely so two instances never run at once.

## Updates

| Layer | How |
| --- | --- |
| Ubuntu, PostgreSQL 16 minor, nginx, Docker engine | `unattended-upgrades` (security pocket), no automatic reboot. `vaultwarden-status` shows pending updates, reboot-required and whether the archive is reachable. A Docker engine update restarts `vaultwarden.service` with it (`PartOf=docker.service`) |
| Vaultwarden | `vaultwarden-upgrade <X.Y.Z> <sha256:digest>`. Read the release notes and the [security advisories](https://github.com/dani-garcia/vaultwarden/security/advisories) first. It backs up, pulls by digest, verifies the digest, restarts, checks the reported version, `/alive` and the web vault, logs to `/var/lib/vaultwarden-appliance/upgrades.log`, and prints the rollback. **Never `latest`, and never a downgrade:** Vaultwarden migrates the schema on start; the way back is the previous image plus the pre-upgrade backup |
| PostgreSQL major, Ubuntu release, new appliance image | Redeploy, don't upgrade in place: new template, procedure B, keep the old VM off but intact until verified |

Upgrading also means rebuilding the template with the new `vaultwarden_version` / `vaultwarden_image_digest` so new deployments start current.

## Test plan

**Automated, every build** (`files/verify.sh`, on the build VM): see [Building the template](#building-the-template). **Automated, every test run** (`Test Vaultwarden Appliance` workflow, empty deploy form): all 34 deploy-form properties survived export, both disks present, `/alive` 200, web vault served, registration refused for an un-invited address, HTTP → 301, `/admin` 403 from the runner, ports 5432/8000/2375/2376/3012 unreachable from the network, the self-generated certificate; on the guest: `vaultwarden-status` healthy, deployment initialized, credentials written, no secret in the settings, ufw rule present; then a **reboot**, after which it must serve again with the **same volume id and RSA key**. **Offline, in CI before any build:** `tests/test_firstboot.py` (identity, settings, env quoting, allowlists, firewall rules, proxy, SSO/SMTP validation) and `tests/test_guard.sh` (every guard refusal).

**Manual acceptance before production** - needs a deployed instance with a trusted certificate and SMTP:

| # | Test | Expect |
| --- | --- | --- |
| 1 | Browser, desktop, mobile (iOS + Android) and extension clients connect | No certificate warnings; login works |
| 2 | Self-registration attempt | Refused |
| 3 | Invite → email → register → login | Works; email verification enforced |
| 4 | Non-creator tries to create an organization | Refused |
| 5 | Org with collections, groups, roles; members see only their collections | As configured |
| 6 | *Require two-step login* policy, member without 2FA | Loses org access until 2FA is set |
| 7 | Register and use a FIDO2 key | Works on the FQDN |
| 8 | Revoke and remove a member; deauthorize in `/admin` | Org items gone from their clients after sync |
| 9 | Wrong master password ×11 from one address | fail2ban bans the address (`fail2ban-client status vaultwarden`) |
| 10 | `/admin` from a non-allowlisted network | 403 |
| 11 | Attachment upload (100 MB) and Send | Work; WebSocket live sync between two clients |
| 12 | `docker kill vaultwarden`; `systemctl restart docker`; `systemctl restart postgresql` | Back within a minute each |
| 13 | Unclean power-off in vCenter | Comes back, data intact |
| 14 | Detach disk 2, boot | Vaultwarden refuses to start; `vaultwarden-status` says data disk not mounted; nothing written to `/` |
| 15 | Attach a blank disk as disk 2 | Nothing mounts (no label); bootstrap and guard refuse with "not mounted"; nothing written to `/` |
| 15b | Attach the data disk of another deployment | Guard refuses (foreign volume id) and prints the adopt command |
| 16 | Restore procedure A, B and D into an isolated network | Validation list passes; original untouched |
| 17 | `vaultwarden-upgrade` to the next release on a copy | Serves; rollback procedure works on a second copy |
| 18 | Veeam job with application-aware processing | Job succeeds; restore test passes |
| 19 | External port scan of the VM | Only 22 (from management), 80, 443 |

## Known limitations

- **Not yet run against vSphere.** Everything above was written against the NetBox appliance's proven build path and checked offline (bootstrap and guard tests, `bash -n`, the deploy-form composition), but the first real build and test run is what will validate the Docker, PostgreSQL and nginx integration on the hardened base.
- **Mobile push notifications** are not configured. They need an installation id and key from `bitwarden.com/host` (`PUSH_ENABLED`, `PUSH_INSTALLATION_ID`, `PUSH_INSTALLATION_KEY`); without them mobile apps sync when opened or refreshed. Add them as an `/admin` setting or extend the form.
- **Docker from the Ubuntu archive** (`docker.io`, `docker-compose-v2`) is in *universe*: security updates arrive through the normal security pocket but are community-maintained unless the host has Ubuntu Pro. Docker's own repository would be fresher at the cost of a third-party apt source.
- **Offline client caches.** Clients keep an encrypted copy of what a user could access; revoking access stops future syncs, it does not reach into a device. Rotate shared credentials on offboarding.
- **OIDC** is prepared for Entra ID (settings, deploy-form fields, documented steps) but has not been exercised against a tenant here; the first SSO test should be on a copy of the appliance. Session revocation at the IdP does not end a Vaultwarden session. A provider with a private CA would need its root added to the container's trust store, which the image does not wire up.
- The umbrella **Test VM Templates** and **Rebuild All VM Templates** workflows do not include this appliance yet: both sit at the fourteen `workflow_dispatch` inputs the repository has proven to work. Run its own build and test workflows.
