"""Exercise the pure logic in netbox-firstboot.py without a vSphere guest.

Everything here runs from a checkout, with no vSphere, no systemd and no
NetBox: the module is imported and its functions are called directly, and the
few that shell out are given a recorder instead of subprocess. The appliance
build runs this before it spends half an hour on a template.

    python3 Appliances/netbox/tests/test_firstboot.py
"""
import base64
import importlib.util
import os
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "files", "netbox-appliance", "netbox-firstboot.py")

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


# --- split_host_port ---------------------------------------------------
check("bare host", fb.split_host_port("db.example.com", "5432")
      == ("db.example.com", "5432"))
check("host:port", fb.split_host_port("db.example.com:5433", "5432")
      == ("db.example.com", "5433"))
check("ipv6 literal", fb.split_host_port("[2001:db8::5]", "5432")
      == ("2001:db8::5", "5432"))
check("ipv6 literal with port", fb.split_host_port("[2001:db8::5]:6000", "5432")
      == ("2001:db8::5", "6000"))
check("bare ipv6 is not split as host:port",
      fb.split_host_port("2001:db8::5", "5432") == ("2001:db8::5", "5432"))

# --- build_database ----------------------------------------------------
local, is_local = fb.build_database({})
check("empty form yields the local socket database",
      is_local and local["HOST"] == "" and local["PASSWORD"] == ""
      and local["USER"] == "netbox", local)

external, is_local = fb.build_database({
    "netbox.db-host": "pg.example.com:5433",
    "netbox.db-name": "nb",
    "netbox.db-user": "nbuser",
    "netbox.db-password": "p@ss:word/with?specials",
})
check("external database keeps a password with URL metacharacters intact",
      not is_local and external["HOST"] == "pg.example.com"
      and external["PORT"] == "5433" and external["NAME"] == "nb"
      and external["PASSWORD"] == "p@ss:word/with?specials", external)

# --- build_redis -------------------------------------------------------
redis = fb.build_redis({})
check("default redis is loopback, databases 0 and 1",
      redis["tasks"]["HOST"] == "localhost"
      and redis["tasks"]["DATABASE"] == 0
      and redis["caching"]["DATABASE"] == 1
      and isinstance(redis["tasks"]["PORT"], int), redis)
redis = fb.build_redis({"netbox.redis-host": "cache:6380",
                        "netbox.redis-password": "s3cret"})
check("external redis parses host, port and password",
      redis["caching"]["HOST"] == "cache"
      and redis["caching"]["PORT"] == 6380
      and redis["tasks"]["PASSWORD"] == "s3cret", redis)

# --- decode_pem --------------------------------------------------------
pem = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
check("raw PEM passes through", fb.decode_pem(pem, "x") == pem.encode())
check("base64 decodes",
      fb.decode_pem(base64.b64encode(pem.encode()).decode(), "x") == pem.encode())
check("base64 with wizard-inserted whitespace decodes",
      fb.decode_pem("  " + base64.b64encode(pem.encode()).decode()[:8] + "\n "
                    + base64.b64encode(pem.encode()).decode()[8:], "x")
      == pem.encode())
try:
    fb.decode_pem("not base64 at all!!", "netbox.tls-cert")
    check("garbage is rejected", False, "no RuntimeError")
except RuntimeError as exc:
    check("garbage is rejected", "netbox.tls-cert" in str(exc), exc)

# --- parse_allowlist ---------------------------------------------------
check("allowlist splits on commas and spaces",
      fb.parse_allowlist("10.0.0.0/8, 192.168.1.5  2001:db8::/32")
      == ["10.0.0.0/8", "192.168.1.5", "2001:db8::/32"])
check("empty allowlist is empty", fb.parse_allowlist("") == [])
check("allowlist drops an nginx directive injection",
      fb.parse_allowlist("10.0.0.0/8, 1.2.3.4; root /etc;") == ["10.0.0.0/8"])
check("allowlist drops a hostname and a typo'd CIDR",
      fb.parse_allowlist("prom.example.com 10.0.0.0/99 10.1.0.0/16")
      == ["10.1.0.0/16"])
check("an entirely invalid allowlist leaves metrics off",
      fb.parse_allowlist("all") == [])

# --- is_dns_name -------------------------------------------------------
for good in ["netbox.lab.example", "nb1", "a-b.example.com", "example.com."]:
    check("accepts DNS name %r" % good, fb.is_dns_name(good))
for bad in ["2001:db8::10", "[2001:db8::10]", "a b", "x;root /etc",
            "line\nbreak", "-lead.example", "", "." * 300]:
    check("rejects %r" % bad, not fb.is_dns_name(bad))
check("accepts an IPv4 literal (nginx handles those in server_name)",
      fb.is_dns_name("192.0.2.10"))

# --- identity ----------------------------------------------------------
fb.local_addresses = lambda: ["192.0.2.10", "2001:db8::10"]
fqdn, hosts, addresses = fb.resolve_identity({"netbox.fqdn": "netbox.lab.example"})
check("explicit fqdn wins", fqdn == "netbox.lab.example", fqdn)
check("allowed hosts carry the fqdn, both addresses and a bracketed ipv6",
      "netbox.lab.example" in hosts and "192.0.2.10" in hosts
      and "2001:db8::10" in hosts and "[2001:db8::10]" in hosts
      and "localhost" in hosts, hosts)
check("allowed hosts have no duplicates", len(hosts) == len(set(hosts)), hosts)

fqdn, hosts, _ = fb.resolve_identity({"hostname": "nb1",
                                      "network.domain": "lab.example"})
check("hostname plus search domain becomes an fqdn",
      fqdn == "nb1.lab.example", fqdn)
check("short name is allowed too", "nb1" in hosts, hosts)

fqdn, hosts, _ = fb.resolve_identity({"netbox.fqdn": "evil.example;root /etc;"})
check("a form FQDN carrying an nginx directive is dropped", fqdn != "evil.example;root /etc;", fqdn)

fb.local_addresses = lambda: ["2001:db8::10"]
fb.socket.gethostname = lambda: "localhost"
fqdn, hosts, addresses = fb.resolve_identity({})
check("with only an IPv6 address, the URL still gets one", fqdn == "2001:db8::10", fqdn)
check("but that IPv6 literal never reaches server_name",
      not fb.is_dns_name(fqdn))

fb.local_addresses = lambda: []
fb.socket.gethostname = lambda: "localhost"
fqdn, hosts, addresses = fb.resolve_identity({})
check("no identity at all still yields a usable host list",
      fqdn == "" and "localhost" in hosts and "127.0.0.1" in hosts,
      (fqdn, hosts))

# --- nginx snippet rendering (the injection sink itself) ---------------
import tempfile, os as _os
tmp = tempfile.mkdtemp()
fb.SNIPPET_SERVER_NAME = os.path.join(tmp, "server-name.conf")
fb.SNIPPET_METRICS = os.path.join(tmp, "metrics.conf")
fb.SNIPPET_HSTS = os.path.join(tmp, "hsts.conf")
fb.run = lambda *a, **k: None  # skip the real `nginx -t`

fb.write_nginx_snippets("netbox.lab.example", ["10.0.0.0/8"], False)
body = open(fb.SNIPPET_SERVER_NAME).read()
check("a good FQDN is written into server_name",
      "server_name netbox.lab.example _;" in body, body)
metrics = open(fb.SNIPPET_METRICS).read()
check("allowlist renders one allow per entry then deny all",
      "allow 10.0.0.0/8;" in metrics and metrics.rstrip().endswith("deny all;"),
      metrics)
check("no HSTS with a self-signed certificate",
      "Strict-Transport-Security" not in open(fb.SNIPPET_HSTS).read())

fb.write_nginx_snippets("2001:db8::10", [], True)
body = open(fb.SNIPPET_SERVER_NAME).read()
check("an IPv6 literal is kept out of server_name",
      "server_name _;" in body and "2001:db8" not in body, body)
check("HSTS only with an operator certificate",
      "Strict-Transport-Security" in open(fb.SNIPPET_HSTS).read())

fb.write_nginx_snippets("x; root /etc;", ["1.2.3.4; root /etc;"], False)
sn = open(fb.SNIPPET_SERVER_NAME).read()
mt = open(fb.SNIPPET_METRICS).read()
check("injection via netbox.fqdn does not reach the snippet",
      "root /etc" not in sn, sn)
check("injection via netbox.metrics-allow does not reach the snippet",
      "root /etc" not in mt, mt)

# --- CSRF_TRUSTED_ORIGINS derivation (as configuration.py computes it) --
ALLOWED = ["nb.example", "192.0.2.10", "2001:db8::10", "[2001:db8::10]",
           "localhost", "127.0.0.1", "[::1]"]
origins = ["https://%s" % h for h in ALLOWED
           if h != "*" and (":" not in h or h.startswith("["))]
check("no unbracketed IPv6 origin is produced",
      "https://2001:db8::10" not in origins, origins)
check("the bracketed IPv6 origin is kept",
      "https://[2001:db8::10]" in origins and "https://[::1]" in origins, origins)
check("names and IPv4 origins survive",
      "https://nb.example" in origins and "https://192.0.2.10" in origins, origins)

# --- system_is_booting: the entire behaviour change ----------------------
import subprocess as _sp
_Completed = _sp.CompletedProcess

def _stub_systemctl(state, rc=0):
    def fake(cmd, **kw):
        assert cmd[:2] == ["systemctl", "is-system-running"], cmd
        return _Completed(cmd, rc, stdout=state + "\n", stderr="")
    return fake

_real_run = fb.subprocess.run
for state, rc, booting in [("initializing", 1, True), ("starting", 1, True),
                           ("running", 0, False), ("degraded", 1, False),
                           ("maintenance", 1, False)]:
    fb.subprocess.run = _stub_systemctl(state, rc)
    check("is-system-running=%-13s -> booting=%-5s" % (state, booting),
          fb.system_is_booting() is booting, fb.system_is_booting())

# And the guard itself: during boot nothing may be asked of systemd, because
# a try-restart would cancel the queued start jobs of the units ordered after
# this one. Outside boot the restart must still happen.
calls = []
def _record(cmd, **kw):
    if cmd[:2] == ["systemctl", "is-system-running"]:
        return _Completed(cmd, 1, stdout=_record.state + "\n", stderr="")
    calls.append(cmd)
    return _Completed(cmd, 0, stdout="", stderr="")

fb.subprocess.run = _record
# An earlier test replaced fb.run with a no-op to skip `nginx -t`; restore a
# real one so restart_services() actually reaches the recorder.
fb.run = lambda cmd, **kw: fb.subprocess.run(cmd, **kw)
_record.state = "starting"
calls.clear(); fb.restart_services()
check("booting -> no systemctl restart is issued", calls == [], calls)

_record.state = "running"
calls.clear(); fb.restart_services()
check("running -> services are restarted", len(calls) == 1 and calls[0][:2] == ["systemctl", "try-reload-or-restart"], calls)
check("from a shell: no --no-block, so the jobs are waited on",
      "--no-block" not in calls[0], calls[0])
check("all three units named",
      set(calls[0][2:]) == {"netbox.service", "netbox-rq.service", "nginx.service"}, calls[0])
fb.subprocess.run = _real_run

# --- in_appliance_unit / the restart deadlock ---------------------------
# netbox-reconcile.service is ordered Before= the three services it restarts,
# so a blocking systemctl inside its own start job waits for jobs systemd will
# not run until that job finishes. On a live appliance that cost the reload a
# just-installed certificate needed, five minutes later, with the unit killed.
import tempfile as _tf2

_cg = os.path.join(_tf2.mkdtemp(), "cgroup")
fb.CGROUP = _cg

for content, expected in [
        ("0::/user.slice/user-1000.slice/session-3.scope\n", False),
        ("0::/system.slice/netbox-reconcile.service\n", True),
        ("0::/system.slice/netbox-bootstrap.service\n", True),
        ("0::/system.slice/sshd.service\n", False)]:
    with open(_cg, "w") as _handle:
        _handle.write(content)
    check("in_appliance_unit(%-46s) -> %s" % (content.strip(), expected),
          fb.in_appliance_unit() is expected, fb.in_appliance_unit())

fb.CGROUP = os.path.join(_tf2.mkdtemp(), "does-not-exist")
check("in_appliance_unit with no cgroup file -> False",
      fb.in_appliance_unit() is False)

# And the behaviour that matters: inside the unit, enqueue instead of wait.
fb.CGROUP = _cg
with open(_cg, "w") as _handle:
    _handle.write("0::/system.slice/netbox-reconcile.service\n")
_record.state = "running"
calls.clear()
fb.subprocess.run = _record
fb.run = lambda cmd, **kw: fb.subprocess.run(cmd, **kw)
fb.restart_services()
check("inside the unit: --no-block, so it cannot deadlock",
      len(calls) == 1 and "--no-block" in calls[0], calls)
check("inside the unit: still all three services",
      set(calls[0][-3:]) == {"netbox.service", "netbox-rq.service",
                             "nginx.service"}, calls[0])
_record.state = "starting"
calls.clear()
fb.restart_services()
check("inside the unit but booting: still nothing at all", calls == [], calls)
fb.subprocess.run = _real_run


# --- reconcile keeps state.json's TLS field in step with the marker ------
# netbox-tls installs an operator certificate long after the bootstrap wrote
# state.json, and netbox-status reads state.json. Before this, a certified
# appliance kept reporting "self-signed" forever.
import json as _json
import tempfile as _tf

_tmp = _tf.mkdtemp()
fb.STATE = os.path.join(_tmp, "state.json")
fb.SELF_SIGNED = os.path.join(_tmp, ".self-signed")
fb.load_config = lambda: {"allowed_hosts": ["netbox.example.com"]}
fb.resolve_identity = lambda props: ("netbox.example.com",
                                     ["netbox.example.com"], ["10.0.0.5"])
fb.write_config = lambda config: None
fb.write_nginx_snippets = lambda *a, **k: None
fb.write_proxy = lambda props: None
fb.generate_certificate = lambda *a, **k: None
fb.restart_services = lambda: None
fb.log = lambda message: None

_bootstrap_state = {"fqdn": "netbox.example.com",
                    "url": "https://netbox.example.com/",
                    "self_signed_certificate": True}
with open(fb.STATE, "w") as _handle:
    _json.dump(_bootstrap_state, _handle)

# No marker: the certificate is the operator's.
fb.reconcile({})
_state = _json.load(open(fb.STATE))
check("reconcile: marker absent -> state says operator-supplied",
      _state["self_signed_certificate"] is False, _state)

# Marker back: the appliance generated it again.
with open(fb.SELF_SIGNED, "w") as _handle:
    _handle.write("DNS:netbox.example.com,IP:10.0.0.5,IP:127.0.0.1\n")
fb.reconcile({})
_state = _json.load(open(fb.STATE))
check("reconcile: marker present -> state says self-signed",
      _state["self_signed_certificate"] is True, _state)
check("reconcile leaves the rest of the state alone",
      _state["fqdn"] == "netbox.example.com"
      and _state["url"] == "https://netbox.example.com/", _state)


print("\n%s" % ("ALL CHECKS PASSED" if ok else "FAILURES PRESENT"))
sys.exit(0 if ok else 1)
