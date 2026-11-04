"""Exercise the pure logic in vaultwarden-firstboot.py without a vSphere guest.

Runs from a checkout, with no vSphere, no systemd, no Docker and no
PostgreSQL: the module is imported and its functions are called directly. The
appliance build runs this before it spends a template build.

    python3 Appliances/vaultwarden/tests/test_firstboot.py
"""
import importlib.util
import os
import re

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                      "files", "vaultwarden-appliance", "vaultwarden-firstboot.py")

spec = importlib.util.spec_from_file_location("firstboot", SCRIPT)
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)
fb.log = lambda message: None

ok = True


def check(label, condition, detail=""):
    global ok
    if not condition:
        ok = False
    print("%-4s %s%s" % ("ok" if condition else "FAIL", label,
                         "" if condition else " -- " + str(detail)))


def no_secrets(name):
    return False


def all_secrets(name):
    return True


# --- identity ------------------------------------------------------------
def identity(props, hostname="vw01", fqdn="vw01", addresses=("192.0.2.5",)):
    return fb.resolve_identity(props, hostname=hostname,
                               fqdn_lookup=lambda: fqdn,
                               addresses=list(addresses))[0]


check("form fqdn wins", identity({"vaultwarden.fqdn": "Vault.Example.com"})
      == "vault.example.com")
check("bare hostname is qualified with network.domain",
      identity({"network.domain": "corp.example.com"}) == "vw01.corp.example.com")
check("an injected fqdn is refused",
      identity({"vaultwarden.fqdn": "x;evil"}, hostname="localhost",
               fqdn="localhost") == "192.0.2.5")
check("no name at all falls back to the first address",
      identity({}, hostname="localhost", fqdn="localhost") == "192.0.2.5")
check("DOMAIN for a name", fb.domain_url("vault.example.com")
      == "https://vault.example.com")
check("DOMAIN brackets IPv6", fb.domain_url("2001:db8::5")
      == "https://[2001:db8::5]")

# --- allowlists ----------------------------------------------------------
check("networks are normalized and invalid entries dropped",
      fb.parse_networks("10.0.0.0/8, 192.0.2.7 bogus;deny 10.1.2.3/16", "x")
      == ["10.0.0.0/8", "192.0.2.7/32", "10.1.0.0/16"])
snippet = fb.render_admin_snippet(["10.0.0.0/8"])
check("admin snippet allows loopback and the list, then denies",
      snippet.splitlines()[-4:] == ["allow 127.0.0.1;", "allow ::1;",
                                    "allow 10.0.0.0/8;", "deny all;"],
      snippet)
check("admin snippet re-checks at the sink",
      "evil" not in fb.render_admin_snippet(["1.2.3.4; evil"]))

# --- firewall ------------------------------------------------------------
rules = fb.firewall_rules([], [])
check("empty https allowlist opens 80,443 from anywhere only",
      rules == [["allow", "proto", "tcp", "from", "any", "to", "any", "port",
                 "80,443", "comment", "vaultwarden-https"]], rules)
rules = fb.firewall_rules(["10.0.0.0/8"], ["192.0.2.0/24"])
check("allowlists produce one rule per source",
      [r[4] for r in rules] == ["10.0.0.0/8", "192.0.2.0/24"]
      and rules[0][8] == "80,443" and rules[1][8] == "22", rules)
# A typo must never widen access: `10.0.0.0/33` is a filled-in field with
# nothing valid in it, which is not the same thing as an empty field.
entries, invalid = fb.allowlist({"vaultwarden.https-allow": "10.0.0.0/33"},
                                "vaultwarden.https-allow")
check("an allowlist with only invalid entries is flagged, not emptied",
      entries == [] and invalid is True)
check("an empty allowlist is empty, not invalid",
      fb.allowlist({}, "vaultwarden.https-allow") == ([], False))
check("a mixed allowlist keeps the valid entries and is not flagged",
      fb.allowlist({"vaultwarden.ssh-allow": "10.0.0.0/33 192.0.2.0/24"},
                   "vaultwarden.ssh-allow") == (["192.0.2.0/24"], False))
check("an invalid HTTPS allowlist installs no HTTPS rule at all",
      fb.firewall_rules([], ["192.0.2.0/24"], https_closed=True)
      == [["allow", "proto", "tcp", "from", "192.0.2.0/24", "to", "any",
           "port", "22", "comment", "vaultwarden-ssh"]])
status = """Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 80,443/tcp                 ALLOW IN    10.0.0.0/8                 # vaultwarden-https
[ 3] 22/tcp                     ALLOW IN    192.0.2.0/24               # vaultwarden-ssh
[ 4] 22/tcp (v6)                ALLOW IN    Anywhere (v6)
[10] 80,443/tcp (v6)            ALLOW IN    Anywhere (v6)              # vaultwarden-https
"""
check("owned ufw rules are found, highest number first",
      fb.owned_rule_numbers(status) == [10, 3, 2], fb.owned_rule_numbers(status))

# --- settings ------------------------------------------------------------
settings = fb.build_settings({}, "vault.example.com", no_secrets)
check("empty form: invitation-only, no SMTP, verification off",
      settings["SIGNUPS_ALLOWED"] == "false"
      and settings["INVITATIONS_ALLOWED"] == "true"
      and settings["SIGNUPS_VERIFY"] == "false"
      and "SMTP_HOST" not in settings, settings)
check("empty form: nobody may create organizations",
      settings["ORG_CREATION_USERS"] == "none")
check("loopback bind and socket database",
      settings["ROCKET_ADDRESS"] == "127.0.0.1"
      and settings["DATABASE_URL"]
      == "postgresql://vaultwarden@/vaultwarden?host=/run/postgresql")
check("hardening defaults", settings["SHOW_PASSWORD_HINT"] == "false"
      and settings["PASSWORD_HINTS_ALLOWED"] == "false"
      and settings["HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS"] == "true"
      and settings["SSO_ENABLED"] == "false")
check("organization groups are off unless the form turns them on",
      settings["ORG_GROUPS_ENABLED"] == "false"
      and fb.build_settings({"vaultwarden.org-groups": "True"}, "v",
                            no_secrets)["ORG_GROUPS_ENABLED"] == "true"
      and fb.build_settings({"vaultwarden.org-groups": "maybe"}, "v",
                            no_secrets)["ORG_GROUPS_ENABLED"] == "false")
check("the proxy drop-ins cover Docker and the directory sync",
      set(os.path.basename(os.path.dirname(p)) for p in fb.PROXY_DROPINS)
      == {"docker.service.d", "vaultwarden-dirsync.service.d"})
check("no *_FILE without its secret", not any(
    key.endswith("_FILE") for key in settings), settings)

smtp_form = {
    "vaultwarden.smtp-host": "smtp.example.com",
    "vaultwarden.smtp-security": "force_tls",
    "vaultwarden.smtp-from": "vault@example.com",
    "vaultwarden.smtp-username": "vault",
    "vaultwarden.org-creators": "Admin@Example.com, not-an-email",
    "vaultwarden.time-zone": "Europe/Prague",
}
settings = fb.build_settings(smtp_form, "vault.example.com", all_secrets)
check("SMTP: port follows security mode, verification on",
      settings["SMTP_PORT"] == "465" and settings["SIGNUPS_VERIFY"] == "true",
      settings)
check("SMTP password comes from a file, never the environment",
      settings["SMTP_PASSWORD_FILE"] == "/run/secrets/smtp_password"
      and "SMTP_PASSWORD" not in settings)
check("admin token comes from a file",
      settings["ADMIN_TOKEN_FILE"] == "/run/secrets/admin_token"
      and "ADMIN_TOKEN" not in settings)
check("org creators are validated and lower-cased",
      settings["ORG_CREATION_USERS"] == "admin@example.com", settings)
check("time zone passes through", settings["TZ"] == "Europe/Prague")
check("an injected time zone is refused",
      fb.build_settings({"vaultwarden.time-zone": "UTC'\nX=1"}, "v",
                        no_secrets)["TZ"] == "UTC")
check("SMTP without a valid sender stays off",
      "SMTP_HOST" not in fb.build_settings(
          {"vaultwarden.smtp-host": "smtp.example.com"}, "v", all_secrets))

sso_form = {"vaultwarden.sso-authority": "https://id.example.com/realms/x/",
            "vaultwarden.sso-client-id": "vw"}
sso = fb.build_settings(sso_form, "v", all_secrets)
check("SSO: enabled with authority, client id and secret, never SSO-only",
      sso["SSO_ENABLED"] == "true" and sso["SSO_ONLY"] == "false"
      and sso["SSO_AUTHORITY"] == "https://id.example.com/realms/x"
      and sso["SSO_CLIENT_SECRET_FILE"] == "/run/secrets/sso_client_secret", sso)
check("SSO defaults: offline_access requested, invite-first, strict email verification",
      sso["SSO_SCOPES"] == "openid profile email offline_access"
      and sso["SSO_SIGNUPS_ALLOWED"] == "false"
      and sso["SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION"] == "false"
      and sso["SSO_SIGNUPS_MATCH_EMAIL"] == "true", sso)
# Vaultwarden refuses to start with SSO_ENABLED and no client secret.
sso = fb.build_settings(sso_form, "v", no_secrets)
check("SSO stays off until the client secret has been supplied",
      sso["SSO_ENABLED"] == "false" and "SSO_AUTHORITY" not in sso
      and not any(k.startswith("SSO_") and k != "SSO_ENABLED" for k in sso), sso)
check("SSO over plain http is refused",
      fb.build_settings({"vaultwarden.sso-authority": "http://id",
                         "vaultwarden.sso-client-id": "vw"}, "v",
                        all_secrets)["SSO_ENABLED"] == "false")
entra = fb.build_settings(dict(sso_form, **{
    "vaultwarden.sso-scopes": "openid profile email offline_access User.Read bad;scope",
    "vaultwarden.sso-signups-allowed": "True",
    "vaultwarden.sso-allow-unknown-email-verification": "yes"}), "v", all_secrets)
check("Entra ID shape: custom scopes filtered, signups and unknown verification on",
      entra["SSO_SCOPES"] == "openid profile email offline_access User.Read"
      and entra["SSO_SIGNUPS_ALLOWED"] == "true"
      and entra["SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION"] == "true", entra)
check("a garbage boolean falls back to the safe default",
      fb.parse_bool("maybe", "x") is False and fb.parse_bool("", "x", True) is True)

# --- env rendering -------------------------------------------------------
rendered = fb.render_env({"A": "plain", "B": "has $dollar and \"quotes\"",
                          "C": "it's", "D": "two\nlines"})
check("values are single-quoted literally",
      "A='plain'" in rendered and "B='has $dollar and \"quotes\"'" in rendered,
      rendered)
check("unquotable values are dropped, not escaped",
      "C=" not in rendered and "D=" not in rendered, rendered)
for line in fb.render_env(fb.build_settings(smtp_form, "vault.example.com",
                                             all_secrets)).splitlines():
    if line and not line.startswith("#"):
        check("well-formed env line: %s" % line.split("=")[0],
              re.match(r"^[A-Z0-9_]+='[^'\n]*'$", line), line)

# --- proxy ---------------------------------------------------------------
check("a proxy with credentials is refused outright",
      fb.proxy_values({"vaultwarden.proxy": "http://u:p@proxy:3128"})[0] == "")
check("a proxy that could break quoting is refused",
      fb.proxy_values({"vaultwarden.proxy": "http://proxy:3128'; x"})[0] == ""
      and fb.proxy_values({"vaultwarden.proxy": 'http://pr"oxy:3128'})[0] == ""
      and fb.proxy_values({"vaultwarden.proxy": "http://pro%41xy:3128"})[0] == "")
check("a plain proxy URL is accepted",
      fb.proxy_values({"vaultwarden.proxy": "http://proxy.example.com:3128"})[0]
      == "http://proxy.example.com:3128")
proxy, no_proxy = fb.proxy_values({"vaultwarden.proxy": "http://proxy:3128",
                                   "vaultwarden.no-proxy": ".corp,10.0.0.0/8,bad;x"})
check("bypass list keeps loopback and valid entries only",
      proxy == "http://proxy:3128"
      and no_proxy == "localhost,127.0.0.1,::1,.corp,10.0.0.0/8", no_proxy)

# --- argon2 --------------------------------------------------------------
check("PHC format check accepts an argon2id hash",
      fb.ARGON2_PHC_RE.match("$argon2id$v=19$m=65540,t=3,p=4$c2FsdHNhbHQ$"
                             "AAAABBBBccccDDDDeeeeFFFFgggg0123456789+/abc"))
check("PHC format check refuses plaintext and argon2i",
      not fb.ARGON2_PHC_RE.match("hunter2")
      and not fb.ARGON2_PHC_RE.match("$argon2i$v=19$m=4096,t=3,p=1$a$b"))

# --- certificates --------------------------------------------------------
names = fb.certificate_names("vault.example.com", "vw01", ["192.0.2.5"])
check("certificate names: fqdn, host, localhost, addresses",
      names == ["DNS:vault.example.com", "DNS:vw01", "DNS:localhost",
                "IP:192.0.2.5", "IP:127.0.0.1"], names)
check("an address-only identity is not a DNS SAN",
      fb.certificate_names("192.0.2.5", "localhost", ["192.0.2.5"])
      == ["DNS:localhost", "IP:192.0.2.5", "IP:127.0.0.1"])

raise SystemExit(0 if ok else 1)
