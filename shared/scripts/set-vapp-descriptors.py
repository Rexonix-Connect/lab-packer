#!/usr/bin/env python3
"""Set category, label, description and ordering on the deploy-form properties.

The packer-plugin-vsphere vapp block only accepts id=value pairs, so the
properties it creates render as uncategorized, mostly unlabeled sections in
random order in the vSphere deploy wizard. This runs as a shell-local
provisioner while the build VM still exists (before the content library
export) and rewrites the property descriptors; ids and values are untouched,
and properties outside the descriptor table are preserved as-is after it.

Application-layer images add their own fields on top of the shared form by
pointing VAPP_EXTRA_DESCRIPTORS at a JSON file (see load_extra_descriptors);
with the variable unset the eleven built-in properties are the whole form,
exactly as before.
"""
import json
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
BASE_DESCRIPTORS = [
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

# The eleven properties every template carries. Only these are required to
# already exist on the build VM; image-specific extras are created.
BASE_IDS = frozenset(descriptor.id for descriptor in BASE_DESCRIPTORS)


def load_extra_descriptors(descriptors):
    """Merge image-specific deploy-form properties into the built-in list.

    VAPP_EXTRA_DESCRIPTORS points at a JSON file so that this script and
    normalize-library-ovf.py (which imports this module) always agree on the
    form's shape:

        {"insert_before": "user-data",
         "descriptors": [{"id": ..., "category": ..., "label": ...,
                          "description": ..., "type": "string"}]}

    insert_before names the built-in property the extras are placed in front
    of, so an image can keep the generic "Advanced" escape hatch last; omit it
    to append. Unset or empty variable leaves the built-in list untouched.
    """
    path = os.environ.get("VAPP_EXTRA_DESCRIPTORS", "").strip()
    if not path:
        return descriptors
    with open(path) as fh:
        spec = json.load(fh)
    extras = [Descriptor(id=entry["id"], category=entry["category"],
                         label=entry["label"],
                         description=entry["description"],
                         type=entry.get("type", "string"))
              for entry in spec.get("descriptors", [])]
    if not extras:
        return descriptors
    clashes = sorted({e.id for e in extras} & {d.id for d in descriptors})
    if clashes:
        sys.exit("set-vapp-descriptors: %s redefines built-in propert%s: %s"
                 % (path, "y" if len(clashes) == 1 else "ies",
                    ", ".join(clashes)))
    anchor = spec.get("insert_before", "")
    if not anchor:
        return descriptors + extras
    ids = [descriptor.id for descriptor in descriptors]
    if anchor not in ids:
        sys.exit("set-vapp-descriptors: %s sets insert_before to %r, which is"
                 " not a built-in property" % (path, anchor))
    index = ids.index(anchor)
    return descriptors[:index] + extras + descriptors[index:]


DESCRIPTORS = load_extra_descriptors(BASE_DESCRIPTORS)


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
    foreign = sorted((prop for prop in existing.values()
                      if prop.id not in known), key=lambda prop: prop.key)
    base = max((prop.key for prop in existing.values()), default=-1) + 1

    specs = [
        vim.vApp.PropertySpec(operation="remove", removeKey=prop.key)
        for prop in existing.values()
    ]
    key = base
    for descriptor in DESCRIPTORS:
        # A descriptor the VM does not carry yet is created empty: that is how
        # an image-specific property first appears on a cloned build VM, whose
        # vAppConfig only has the source template's properties.
        current = existing.get(descriptor.id)
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
                value=(current.value if current else "") or "",
            )))
        key += 1
    for prop in foreign:
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
    return specs, foreign


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
        missing = [d.id for d in DESCRIPTORS
                   if d.id in BASE_IDS and d.id not in existing]
        if missing:
            sys.exit("set-vapp-descriptors: VM lacks expected properties: %s"
                     % ", ".join(missing))
        created = [d.id for d in DESCRIPTORS if d.id not in existing]

        specs, foreign = build_property_specs(existing)
        WaitForTask(vm.ReconfigVM_Task(
            spec=vim.vm.ConfigSpec(
                vAppConfig=vim.vApp.VmConfigSpec(property=specs))))
        message = ("set-vapp-descriptors: categorized, labeled and ordered %d"
                   " deploy-form properties on %s" % (len(DESCRIPTORS), vm_name))
        if created:
            message += " (added %d image-specific properties: %s)" % (
                len(created), ", ".join(created))
        if foreign:
            message += " (preserved %d other properties: %s)" % (
                len(foreign), ", ".join(prop.id for prop in foreign))
        print(message)
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
