#!/usr/bin/env python3
"""Apply network settings from the vSphere OVF environment via netplan.

Runs before systemd-networkd on every boot (see ovf-network.service), so
editing the vApp properties and rebooting re-applies them. Fails open: any
error leaves the existing network configuration untouched.
"""
import ipaddress
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

NETPLAN = "/etc/netplan/90-ovf.yaml"
OVF_NS = "{http://schemas.dmtf.org/ovf/environment/1}"
NET_KEYS = ("network.ip4", "network.gw4", "network.ip6", "network.gw6",
            "network.dns", "network.domain")


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
    for address in filter(None, [gw4, gw6]) :
        ipaddress.ip_address(address)
    for server in dns:
        ipaddress.ip_address(server)

    lines = [
        "# Written by ovf-network.service from OVF environment properties.",
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


def remove_config():
    if os.path.exists(NETPLAN):
        os.remove(NETPLAN)
        subprocess.run(["netplan", "generate"], timeout=30)


def main():
    xml_text = get_ovf_env()
    if not xml_text:
        return remove_config()
    props = parse_props(xml_text)
    if not any(props.get(key) for key in NET_KEYS):
        return remove_config()
    ifname = pick_interface()
    if not ifname:
        print("ovf-network: no ethernet interface found", file=sys.stderr)
        return
    content = build_netplan(props, ifname)
    current = None
    if os.path.exists(NETPLAN):
        with open(NETPLAN) as fh:
            current = fh.read()
    if content != current:
        fd = os.open(NETPLAN, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        subprocess.run(["netplan", "generate"], timeout=30)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never block boot
        print("ovf-network: %s" % exc, file=sys.stderr)
    sys.exit(0)
