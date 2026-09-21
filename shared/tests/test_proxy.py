"""Exercise shared/appliance/proxy.py against a temporary tree.

No appliance, no systemd, no root: apply() takes a root prefix and a run()
stand-in, so every path it touches lands in a temporary directory.

    python3 shared/tests/test_proxy.py
"""
import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "appliance", "proxy.py")

spec = importlib.util.spec_from_file_location("proxy", MODULE)
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)

ok = True
messages = []
commands = []


def check(label, condition, detail=""):
    global ok
    if not condition:
        ok = False
    print("%-4s %s%s" % ("ok" if condition else "FAIL", label,
                         "" if condition else " -- " + str(detail)))


def log(message):
    messages.append(message)


def run(command, **kwargs):
    commands.append(command)


SPEC = proxy.Spec(
    proxy_property="test.proxy",
    bypass_property="test.no-proxy",
    apt_config="/etc/apt/apt.conf.d/95test-proxy",
    dropins=("/etc/systemd/system/thing.service.d/30-proxy.conf",),
    attribution="test-firstboot.py",
)


class Tree(object):
    """A temporary root, with helpers to read what apply() wrote."""

    def __enter__(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "etc"), exist_ok=True)
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.root, ignore_errors=True)

    def path(self, absolute):
        return os.path.join(self.root, absolute.lstrip("/"))

    def read(self, absolute):
        with open(self.path(absolute)) as handle:
            return handle.read()

    def exists(self, absolute):
        return os.path.exists(self.path(absolute))

    def mode(self, absolute):
        return os.stat(self.path(absolute)).st_mode & 0o777

    def seed(self, absolute, content):
        target = self.path(absolute)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as handle:
            handle.write(content)

    def apply(self, props):
        del messages[:]
        del commands[:]
        return proxy.apply(props, SPEC, log, run=run, root=self.root)


# --- validation --------------------------------------------------------
check("plain host:port accepted",
      bool(proxy.PROXY_RE.match("http://proxy.example.com:3128")))
check("https accepted", bool(proxy.PROXY_RE.match("https://proxy.example.com")))
check("credentials accepted",
      bool(proxy.PROXY_RE.match("http://user:pass@proxy.example.com:3128")))
check("trailing slash accepted",
      bool(proxy.PROXY_RE.match("http://proxy.example.com:3128/")))
# Each of these could terminate one of the three quoting contexts the value
# lands in; all are refused rather than escaped three different ways.
for bad in ('http://proxy.example.com"; Acquire::http::Proxy "http://evil',
            "http://proxy.example.com\nEnvironment=evil=1",
            "http://proxy.example.com:3128/path",
            "ftp://proxy.example.com",
            "proxy.example.com:3128",
            "http://proxy.example.com;evil",
            "http://proxy example.com"):
    check("refused: %r" % bad[:44], not proxy.PROXY_RE.match(bad))

# --- scrub -------------------------------------------------------------
check("password redacted",
      proxy.scrub("http://user:s3cret@proxy.example.com:3128")
      == "http://<redacted>@proxy.example.com:3128")
check("no credentials left alone",
      proxy.scrub("http://proxy.example.com:3128")
      == "http://proxy.example.com:3128")
check("empty is safe", proxy.scrub("") == "")

# --- bypass parsing ----------------------------------------------------
check("hosts, domains and CIDRs survive",
      proxy.parse_bypass(".internal.example.com, 10.0.0.0/8 nb01", log)
      == [".internal.example.com", "10.0.0.0/8", "nb01"])
check("duplicates collapse",
      proxy.parse_bypass("a.example.com a.example.com", log)
      == ["a.example.com"])
check("a value with a quote is refused",
      proxy.parse_bypass('evil"entry', log) == [])
check("empty yields nothing", proxy.parse_bypass("", log) == [])

# --- applying a proxy --------------------------------------------------
with Tree() as tree:
    tree.seed("/etc/environment", 'PATH="/usr/bin"\n')
    result = tree.apply({"test.proxy": "http://proxy.example.com:3128",
                         "test.no-proxy": "10.0.0.0/8"})
    environment = tree.read("/etc/environment")
    check("the pre-existing environment survives",
          'PATH="/usr/bin"' in environment, environment)
    check("all four proxy variables are written",
          all("%s=http://proxy.example.com:3128" % name in environment
              for name in ("http_proxy", "https_proxy",
                           "HTTP_PROXY", "HTTPS_PROXY")), environment)
    check("loopback is always bypassed",
          "no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8" in environment,
          environment)
    check("apt configuration written",
          tree.exists("/etc/apt/apt.conf.d/95test-proxy"))
    check("apt configuration is 0600 (it may carry a password)",
          tree.mode("/etc/apt/apt.conf.d/95test-proxy") == 0o600)
    check("drop-in written",
          tree.exists("/etc/systemd/system/thing.service.d/30-proxy.conf"))
    check("drop-in is 0600",
          tree.mode("/etc/systemd/system/thing.service.d/30-proxy.conf") == 0o600)
    check("environment stays world-readable",
          tree.mode("/etc/environment") == 0o644)
    check("result reports the change", result.changed and result.proxy)
    check("daemon-reload was run",
          ["systemctl", "daemon-reload"] in commands, commands)

    # Re-applying the same settings must not report a change: an appliance
    # whose container runtime reads the proxy at daemon start uses this to
    # decide whether to restart, and a false positive bounces it every boot.
    result = tree.apply({"test.proxy": "http://proxy.example.com:3128",
                         "test.no-proxy": "10.0.0.0/8"})
    check("re-applying the same proxy reports no change", not result.changed)
    check("no daemon-reload on an unchanged run", commands == [], commands)

    # Changing it must report a change.
    result = tree.apply({"test.proxy": "http://other.example.com:8080",
                         "test.no-proxy": "10.0.0.0/8"})
    check("changing the proxy reports a change", result.changed)
    check("exactly one managed block after a change",
          tree.read("/etc/environment").count(proxy.MARK_BEGIN) == 1,
          tree.read("/etc/environment"))

# --- clearing a proxy --------------------------------------------------
with Tree() as tree:
    tree.seed("/etc/environment", 'PATH="/usr/bin"\n')
    tree.apply({"test.proxy": "http://proxy.example.com:3128"})
    result = tree.apply({})
    environment = tree.read("/etc/environment")
    check("clearing removes the managed block",
          proxy.MARK_BEGIN not in environment and "http_proxy" not in environment,
          environment)
    check("clearing keeps the rest of the file",
          'PATH="/usr/bin"' in environment, environment)
    check("clearing removes the apt configuration",
          not tree.exists("/etc/apt/apt.conf.d/95test-proxy"))
    check("clearing removes the drop-in",
          not tree.exists("/etc/systemd/system/thing.service.d/30-proxy.conf"))
    check("clearing reports a change", result.changed)
    result = tree.apply({})
    check("clearing an already-clear appliance reports no change",
          not result.changed)

# --- a refused value clears rather than half-applies -------------------
with Tree() as tree:
    tree.seed("/etc/environment", 'PATH="/usr/bin"\n')
    tree.apply({"test.proxy": "http://good.example.com:3128"})
    result = tree.apply({"test.proxy": 'http://evil"; Acquire::x "y'})
    check("a refused proxy leaves no proxy configured", result.proxy == "")
    check("a refused proxy removes the previous one",
          "http_proxy" not in tree.read("/etc/environment"))
    check("the refusal is logged",
          any("ignoring test.proxy" in m for m in messages), messages)

with Tree() as tree:
    result = tree.apply({"test.proxy": "http://user:s3cret@proxy.example.com"
                                       " and some junk"})
    check("a refused value is not logged in the clear",
          not any("s3cret" in m for m in messages), messages)

# --- an appliance upgraded from the pre-shared layout ------------------
with Tree() as tree:
    tree.seed("/etc/environment",
              'PATH="/usr/bin"\n'
              "# --- netbox-firstboot proxy (managed) ---\n"
              "http_proxy=http://old.example.com:3128\n"
              "no_proxy=localhost\n"
              "# --- end netbox-firstboot proxy ---\n")
    tree.apply({"test.proxy": "http://new.example.com:3128"})
    environment = tree.read("/etc/environment")
    check("a legacy managed block is replaced, not duplicated",
          "old.example.com" not in environment
          and environment.count(proxy.MARK_BEGIN) == 1
          and environment.count("http_proxy=http://new.example.com:3128") == 1,
          environment)
    check("the legacy markers are gone",
          "netbox-firstboot proxy" not in environment, environment)

print()
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
