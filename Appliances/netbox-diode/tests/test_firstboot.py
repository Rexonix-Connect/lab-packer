"""Exercise the pure logic in diode-firstboot.py without a vSphere guest.

Everything here runs from a checkout, with no vSphere, no systemd and no
Docker: the module is imported and its functions are called directly. The
appliance build runs this before it spends fifteen minutes and several
gigabytes of image pulls on a template.

    python3 Appliances/netbox-diode/tests/test_firstboot.py
"""
import base64
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "files", "diode-appliance",
                      "diode-firstboot.py")
ENV_TEMPLATE = os.path.join(HERE, "..", "files", "diode-appliance", "compose",
                            "env.template")
CLIENTS_TEMPLATE = os.path.join(HERE, "..", "files", "diode-appliance",
                                "compose", "oauth2", "client",
                                "client-credentials.json.template")
COMPOSE = os.path.join(HERE, "..", "files", "diode-appliance", "compose",
                       "docker-compose.yaml")

spec = importlib.util.spec_from_file_location("firstboot", SCRIPT)
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)

ok = True


def check(label, condition, detail=""):
    global ok
    if not condition:
        ok = False
    print("%-4s %s%s" % ("ok" if condition else "FAIL", label,
                         "" if condition else " -- " + str(detail)))


# --- netbox_plugin_url -------------------------------------------------
# Operators type what they browse to, not the plugin's API path. Getting this
# wrong means the reconciler retries forever against a 404, which looks like a
# Diode fault and is not one.
check("bare host gets https and the plugin path",
      fb.netbox_plugin_url("netbox.example.com")
      == "https://netbox.example.com/api/plugins/diode")
check("https URL gets the plugin path",
      fb.netbox_plugin_url("https://netbox.example.com")
      == "https://netbox.example.com/api/plugins/diode")
check("trailing slash is not doubled",
      fb.netbox_plugin_url("https://netbox.example.com/")
      == "https://netbox.example.com/api/plugins/diode")
check("an already-complete URL is left alone",
      fb.netbox_plugin_url("https://netbox.example.com/api/plugins/diode")
      == "https://netbox.example.com/api/plugins/diode")
check("http is preserved rather than forced to https",
      fb.netbox_plugin_url("http://netbox.internal:8080")
      == "http://netbox.internal:8080/api/plugins/diode")
check("empty stays empty", fb.netbox_plugin_url("  ") == "")

# --- truthy ------------------------------------------------------------
# The deploy form's boolean properties arrive as strings, and vCenter is not
# consistent about which string.
for value in ("true", "True", "TRUE", "yes", "1", "on"):
    check("truthy(%r)" % value, fb.truthy(value))
for value in ("false", "no", "0", "", "  ", "maybe"):
    check("not truthy(%r)" % value, not fb.truthy(value))

# --- decode_pem --------------------------------------------------------
pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
check("base64 PEM decodes",
      fb.decode_pem(base64.b64encode(pem.encode()).decode(), "cert") == pem)
check("PEM pasted directly is accepted",
      fb.decode_pem(pem, "cert") == pem)
check("a missing trailing newline is added",
      fb.decode_pem(pem.rstrip("\n"), "cert").endswith("\n"))
check("base64 of something that is not PEM is rejected",
      fb.decode_pem(base64.b64encode(b"hello").decode(), "cert") == "")
check("empty stays empty", fb.decode_pem("", "cert") == "")

# --- parse_allowlist ---------------------------------------------------
check("addresses and CIDRs survive",
      fb.parse_allowlist("10.0.0.0/8, 192.0.2.5 2001:db8::/32")
      == ["10.0.0.0/8", "192.0.2.5", "2001:db8::/32"])
check("a host name is refused rather than passed into nginx",
      fb.parse_allowlist("monitoring.example.com") == [])
check("empty yields an empty list", fb.parse_allowlist("") == [])

# --- is_dns_name -------------------------------------------------------
check("valid fqdn", fb.is_dns_name("diode.example.com"))
check("single label", fb.is_dns_name("diode"))
check("leading hyphen refused", not fb.is_dns_name("-diode.example.com"))
check("space refused", not fb.is_dns_name("diode example.com"))
check("empty refused", not fb.is_dns_name(""))

# --- template coverage -------------------------------------------------
# The property this appliance rests on: the template in the image carries no
# secret, and first boot substitutes every placeholder in it. A placeholder
# the script does not know about would ship as the literal string
# "__SOMETHING__" and the container would start with it as a password.
with open(ENV_TEMPLATE) as handle:
    env_text = handle.read()
env_placeholders = set(re.findall(r"__[A-Z0-9_]+__", env_text))
# __DIODE_TAG__ is substituted at BUILD time by install-diode.sh, not at first
# boot, so it is expected to be absent from the deployed template.
env_placeholders.discard("__DIODE_TAG__")

source = open(SCRIPT).read()
handled = set(re.findall(r"'(__[A-Z0-9_]+__)'", source))
missing = sorted(env_placeholders - handled)
check("every env.template placeholder is substituted at first boot",
      not missing, "unhandled: %s" % missing)

with open(CLIENTS_TEMPLATE) as handle:
    clients_text = handle.read()
client_placeholders = set(re.findall(r"__[A-Z0-9_]+__", clients_text))
declared = {placeholder for placeholder, _ in fb.CLIENT_SECRETS}
check("every OAuth2 client placeholder is declared in CLIENT_SECRETS",
      client_placeholders == declared,
      "template: %s declared: %s" % (sorted(client_placeholders),
                                     sorted(declared)))

# Each client needs a generated secret under its own name in secrets_map.
# bootstrap() builds that dict literally, so check the names line up rather
# than discovering it on a deployed appliance.
for placeholder, client in fb.CLIENT_SECRETS:
    check("bootstrap generates a secret for %s" % client,
          "'%s': generate_secret()" % client in source)

# --- the proxy spec ----------------------------------------------------
# The rules live in shared/appliance/proxy.py and are tested there. What is
# worth asserting on this side is that this appliance wired the right things
# into them: its own form properties, its own apt file, and a drop-in for the
# Docker daemon - dockerd is what pulls images, and without it a proxied site
# cannot reach a registry.
check("the proxy spec reads this appliance's form properties",
      fb.PROXY_SPEC.proxy_property == "diode.proxy"
      and fb.PROXY_SPEC.bypass_property == "diode.no-proxy",
      (fb.PROXY_SPEC.proxy_property, fb.PROXY_SPEC.bypass_property))
check("the apt configuration does not collide with the NetBox appliance's",
      fb.PROXY_SPEC.apt_config == "/etc/apt/apt.conf.d/95diode-proxy",
      fb.PROXY_SPEC.apt_config)
check("the Docker daemon gets a drop-in so image pulls are proxied",
      fb.PROXY_SPEC.dropins
      == ("/etc/systemd/system/docker.service.d/30-proxy.conf",),
      fb.PROXY_SPEC.dropins)

# --- compose/env agreement ---------------------------------------------
# Upstream adds environment variables between releases. A variable the compose
# file references but env.template does not set makes the container start with
# it EMPTY - which is how you get a stack that comes up and silently does
# nothing. This is the check that catches a careless re-vendor.
with open(COMPOSE) as handle:
    compose_text = handle.read()
referenced = set(re.findall(r"\$\{([A-Z0-9_]+)(?::-[^}]*)?\}", compose_text))
# Variables with a default in the compose file do not need to be set.
defaulted = set(re.findall(r"\$\{([A-Z0-9_]+):-[^}]*\}", compose_text))
defined = set(re.findall(r"^([A-Z0-9_]+)=", env_text, re.MULTILINE))
undefined = sorted(referenced - defaulted - defined)
check("every compose variable is set by env.template",
      not undefined, "not set: %s" % undefined)

print()
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
