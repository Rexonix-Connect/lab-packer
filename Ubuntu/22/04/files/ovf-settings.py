#!/usr/bin/env python3
"""Apply deploy-time settings from the vSphere OVF environment.

network.* properties become a netplan override; the username property becomes
a cloud-init default_user override, so the form's password/public-keys apply
to the chosen account. Runs before systemd-networkd and cloud-init on every
boot (see ovf-settings.service); network settings re-apply on reboot, while
the username only matters on the first boot of a deployment. Fails open: any
error leaves the existing configuration untouched.
"""
import ipaddress
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

NETPLAN = "/etc/netplan/90-ovf.yaml"
USER_CFG = "/etc/cloud/cloud.cfg.d/91-ovf-user.cfg"
OVF_NS = "{http://schemas.dmtf.org/ovf/environment/1}"
NET_KEYS = ("network.ip4", "network.gw4", "network.ip6", "network.gw6",
            "network.dns", "network.domain")
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
RESERVED_USERNAMES = {"root", "vagrant", "recovery", "administrator"}


def get_ovf_env():
    # A file argument replaces the rpc transport, for tests and debugging.
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as fh:
            return fh.read()
    for cmd in (["vmware-rpctool", "info-get guestinfo.ovfEnv"],
                ["vmtoolsd", "--cmd", "info-get guestinfo.ovfEnv"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if out.returncode == 0 and out.stdout.lstrip().startswith("<?xml"):
            return out.stdout
    return None


def parse_props(xml_text):
    # vSphere emits Property elements in the OVF environment default
    # namespace with oe:-prefixed attributes; accept bare names too for
    # other OVF deployers.
    props = {}
    for prop in ET.fromstring(xml_text).iter():
        if not prop.tag.endswith("Property"):
            continue
        key = prop.get(OVF_NS + "key") or prop.get("key")
        value = prop.get(OVF_NS + "value")
        if value is None:
            value = prop.get("value")
        if key and value is not None:
            props[key] = value.strip()
    return props


def split_list(value):
    return [item for item in value.replace(",", " ").split() if item]


def pick_interface():
    names = sorted(name for name in os.listdir("/sys/class/net")
                   if name.startswith(("en", "eth")))
    return names[0] if names else None


def build_netplan(props, ifname):
    ip4 = props.get("network.ip4", "")
    gw4 = props.get("network.gw4", "")
    ip6 = props.get("network.ip6", "")
    gw6 = props.get("network.gw6", "")
    dns = split_list(props.get("network.dns", ""))
    search = split_list(props.get("network.domain", ""))

    addresses = []
    if ip4:
        ipaddress.ip_interface(ip4)
        addresses.append(ip4)
    if ip6:
        ipaddress.ip_interface(ip6)
        addresses.append(ip6)
    for address in filter(None, [gw4, gw6]):
        ipaddress.ip_address(address)
    for server in dns:
        ipaddress.ip_address(server)

    lines = [
        "# Written by ovf-settings.service from OVF environment properties.",
        "network:",
        "  version: 2",
        "  ethernets:",
        "    %s:" % ifname,
        "      dhcp4: %s" % ("false" if ip4 else "true"),
        "      accept-ra: %s" % ("false" if ip6 else "true"),
    ]
    if addresses:
        lines.append("      addresses:")
        lines.extend("        - \"%s\"" % address for address in addresses)
    routes = [("0.0.0.0/0", gw4)] if gw4 else []
    if gw6:
        routes.append(("::/0", gw6))
    if routes:
        lines.append("      routes:")
        for to, via in routes:
            lines.append("        - to: \"%s\"" % to)
            lines.append("          via: \"%s\"" % via)
    if dns or search:
        lines.append("      nameservers:")
        if dns:
            lines.append("        addresses: [%s]"
                         % ", ".join("\"%s\"" % server for server in dns))
        if search:
            lines.append("        search: [%s]"
                         % ", ".join("\"%s\"" % domain for domain in search))
    return "\n".join(lines) + "\n"


def build_user_cfg(username):
    # Complete default_user spec (Ubuntu server defaults) rather than relying
    # on cloud-init's fragment merge depth; the form's password/public-keys
    # target the default user, so they follow the rename automatically.
    return "\n".join([
        "# Written by ovf-settings.service from OVF environment properties.",
        "system_info:",
        "  default_user:",
        "    name: %s" % username,
        "    gecos: %s" % username,
        "    groups: [adm, cdrom, dip, lxd, plugdev, sudo]",
        "    lock_passwd: true",
        "    shell: /bin/bash",
        "    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]",
    ]) + "\n"


def write_if_changed(path, content, run_after=None):
    current = None
    if os.path.exists(path):
        with open(path) as fh:
            current = fh.read()
    if content != current:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        if run_after:
            subprocess.run(run_after, timeout=30)


def remove_if_present(path, run_after=None):
    if os.path.exists(path):
        os.remove(path)
        if run_after:
            subprocess.run(run_after, timeout=30)


def apply_user(props):
    username = props.get("username", "")
    if not username:
        return remove_if_present(USER_CFG)
    if not USERNAME_RE.match(username) or username.lower() in RESERVED_USERNAMES:
        print("ovf-settings: ignoring invalid or reserved username %r"
              % username, file=sys.stderr)
        return remove_if_present(USER_CFG)
    write_if_changed(USER_CFG, build_user_cfg(username))


def apply_network(props):
    if not any(props.get(key) for key in NET_KEYS):
        return remove_if_present(NETPLAN, ["netplan", "generate"])
    ifname = pick_interface()
    if not ifname:
        print("ovf-settings: no ethernet interface found", file=sys.stderr)
        return
    write_if_changed(NETPLAN, build_netplan(props, ifname),
                     ["netplan", "generate"])


def main():
    xml_text = get_ovf_env()
    props = parse_props(xml_text) if xml_text else {}
    apply_user(props)
    apply_network(props)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never block boot
        print("ovf-settings: %s" % exc, file=sys.stderr)
    sys.exit(0)
