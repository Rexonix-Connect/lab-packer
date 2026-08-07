#!/usr/bin/env python3
"""Set category, label, description and ordering on the deploy-form properties.

The packer-plugin-vsphere vapp block only accepts id=value pairs, so the
properties it creates render as uncategorized, mostly unlabeled sections in
random order in the vSphere deploy wizard. This runs as a shell-local
provisioner while the build VM still exists (before the content library
export) and rewrites the property descriptors; ids and values are untouched,
and properties outside the descriptor table are preserved as-is after it.
"""
import os
import ssl
import sys
from typing import NamedTuple

from pyVim.connect import Disconnect, SmartConnect
from pyVim.task import WaitForTask
from pyVmomi import vim


class Descriptor(NamedTuple):
    id: str
    category: str
    label: str
    description: str
    type: str = "string"


# In the order the deploy wizard shows: identity, network (IPv4 pair, IPv6
# pair, then DNS), and the advanced escape hatch last. The library OVF is
# normalized to this order by normalize-library-ovf.py after export, because
# the vCenter export scrambles property order.
DESCRIPTORS = [
    Descriptor("hostname", "Guest Identity", "Hostname",
               "Guest hostname; empty keeps the template default"),
    Descriptor("username", "Guest Identity", "Username",
               "Managed admin account (Linux first-boot default user /"
               " Windows local Administrators member); empty means"
               " ubuntu / Administrator"),
    Descriptor("password", "Guest Identity", "Password",
               "Password for the managed admin account; empty keeps the"
               " account's existing password", type="password"),
    Descriptor("public-keys", "Guest Identity", "SSH Public Keys",
               "SSH public key(s) authorized for the managed admin account;"
               " separate multiple keys with commas or new lines"),
    Descriptor("network.ip4", "Guest Network", "IPv4 Address (CIDR)",
               "Static IPv4 address, e.g. 192.168.10.5/24; empty means DHCP"),
    Descriptor("network.gw4", "Guest Network", "IPv4 Gateway",
               "IPv4 default gateway"),
    Descriptor("network.ip6", "Guest Network", "IPv6 Address (CIDR)",
               "Static IPv6 address, e.g. 2001:db8::5/64; empty means"
               " SLAAC/router advertisements"),
    Descriptor("network.gw6", "Guest Network", "IPv6 Gateway",
               "IPv6 default gateway"),
    Descriptor("network.dns", "Guest Network", "DNS Servers",
               "DNS servers, space or comma separated, IPv4 and IPv6 mixed"
               " freely"),
    Descriptor("network.domain", "Guest Network", "DNS Search Domains",
               "DNS search domain(s), space or comma separated"),
    Descriptor("user-data", "Advanced", "User Data (base64)",
               "Advanced usage: base64-encoded cloud-config (Linux) or"
               " Cloudbase-Init userdata (Windows), applied in addition to"
               " the fields above"),
]


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit("set-vapp-descriptors: %s is not set" % name)
    return value


def find_vm(content, vm_name, datacenter):
    # Direct inventory-path lookup first (the builds place VMs in the root VM
    # folder); fall back to a container-view scan for non-default layouts.
    if datacenter:
        vm = content.searchIndex.FindByInventoryPath(
            "/%s/vm/%s" % (datacenter, vm_name))
        if vm is not None:
            return vm
    view = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True)
    try:
        return next((m for m in view.view if m.name == vm_name), None)
    finally:
        view.Destroy()


def build_property_specs(existing):
    """Return VAppPropertySpec list: remove everything, re-add DESCRIPTORS in
    order with descriptors set, then preserve any other properties as-is.

    Keys are immutable and drive the wizard's ordering, so ordering requires
    remove+add; new keys start past the current maximum to avoid remove/add
    key collisions within one reconfigure.
    """
    known = {descriptor.id for descriptor in DESCRIPTORS}
    extras = sorted((prop for prop in existing.values()
                     if prop.id not in known), key=lambda prop: prop.key)
    base = max((prop.key for prop in existing.values()), default=-1) + 1

    specs = [
        vim.vApp.PropertySpec(operation="remove", removeKey=prop.key)
        for prop in existing.values()
    ]
    key = base
    for descriptor in DESCRIPTORS:
        specs.append(vim.vApp.PropertySpec(
            operation="add",
            info=vim.vApp.PropertyInfo(
                key=key,
                id=descriptor.id,
                category=descriptor.category,
                label=descriptor.label,
                description=descriptor.description,
                type=descriptor.type,
                userConfigurable=True,
                value=existing[descriptor.id].value or "",
            )))
        key += 1
    for prop in extras:
        specs.append(vim.vApp.PropertySpec(
            operation="add",
            info=vim.vApp.PropertyInfo(
                key=key,
                id=prop.id,
                category=prop.category,
                label=prop.label,
                description=prop.description,
                type=prop.type or "string",
                userConfigurable=prop.userConfigurable,
                value=prop.value or "",
            )))
        key += 1
    return specs, extras


def main():
    host = env("VCENTER_SERVER")
    username = env("VCENTER_USERNAME")
    password = env("VCENTER_PASSWORD")
    vm_name = env("VM_NAME")
    datacenter = os.environ.get("VCENTER_DATACENTER", "")
    insecure = os.environ.get("VCENTER_INSECURE", "false").lower() == "true"

    context = ssl.create_default_context()
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    si = SmartConnect(host=host, user=username, pwd=password,
                      sslContext=context)
    try:
        content = si.RetrieveContent()
        vm = find_vm(content, vm_name, datacenter)
        if vm is None:
            sys.exit("set-vapp-descriptors: VM %r not found" % vm_name)

        vapp = vm.config.vAppConfig
        existing = {p.id: p for p in (vapp.property if vapp else [])}
        missing = [d.id for d in DESCRIPTORS if d.id not in existing]
        if missing:
            sys.exit("set-vapp-descriptors: VM lacks expected properties: %s"
                     % ", ".join(missing))

        specs, extras = build_property_specs(existing)
        WaitForTask(vm.ReconfigVM_Task(
            spec=vim.vm.ConfigSpec(
                vAppConfig=vim.vApp.VmConfigSpec(property=specs))))
        message = ("set-vapp-descriptors: categorized, labeled and ordered %d"
                   " deploy-form properties on %s" % (len(DESCRIPTORS), vm_name))
        if extras:
            message += " (preserved %d other properties: %s)" % (
                len(extras), ", ".join(prop.id for prop in extras))
        print(message)
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
