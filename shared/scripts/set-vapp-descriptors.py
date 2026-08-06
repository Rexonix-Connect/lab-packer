#!/usr/bin/env python3
"""Set category, label, description and ordering on the deploy-form properties.

The packer-plugin-vsphere vapp block only accepts id=value pairs, so the
properties it creates render as uncategorized, mostly unlabeled sections in
random order in the vSphere deploy wizard. This runs as a shell-local
provisioner while the build VM still exists (before the content library
export) and rewrites the property descriptors; ids and values are untouched.
"""
import os
import ssl
import sys

from pyVim.connect import Disconnect, SmartConnect
from pyVim.task import WaitForTask
from pyVmomi import vim

# (id, category, label, description) in the order the deploy wizard shows.
DESCRIPTORS = [
    ("hostname", "Guest Identity", "Hostname",
     "Guest hostname; empty keeps the template default"),
    ("username", "Guest Identity", "Username",
     "Managed admin account (Linux first-boot default user / Windows local"
     " Administrators member); empty means ubuntu / Administrator"),
    ("password", "Guest Identity", "Password",
     "Password for the managed admin account"),
    ("public-keys", "Guest Identity", "SSH Public Keys",
     "SSH public keys authorized for the managed admin account"),
    ("user-data", "Guest Identity", "User Data (base64)",
     "base64-encoded cloud-config (Linux) or Cloudbase-Init userdata"
     " (Windows) for anything beyond the basic fields"),
    ("network.ip4", "Guest Network", "IPv4 Address (CIDR)",
     "Static IPv4 address, e.g. 192.168.10.5/24; empty means DHCP"),
    ("network.gw4", "Guest Network", "IPv4 Gateway",
     "IPv4 default gateway"),
    ("network.ip6", "Guest Network", "IPv6 Address (CIDR)",
     "Static IPv6 address, e.g. 2001:db8::5/64; empty means"
     " SLAAC/router advertisements"),
    ("network.gw6", "Guest Network", "IPv6 Gateway",
     "IPv6 default gateway"),
    ("network.dns", "Guest Network", "DNS Servers",
     "DNS servers, space or comma separated, IPv4 and IPv6 mixed freely"),
    ("network.domain", "Guest Network", "DNS Search Domains",
     "DNS search domain(s), space or comma separated"),
]


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit("set-vapp-descriptors: %s is not set" % name)
    return value


def main():
    host = env("VCENTER_SERVER")
    username = env("VCENTER_USERNAME")
    password = env("VCENTER_PASSWORD")
    vm_name = env("VM_NAME")
    insecure = os.environ.get("VCENTER_INSECURE", "false").lower() == "true"

    context = ssl.create_default_context()
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    si = SmartConnect(host=host, user=username, pwd=password,
                      sslContext=context)
    try:
        content = si.RetrieveContent()
        view = content.viewManager.CreateContainerView(
            content.rootFolder, [vim.VirtualMachine], True)
        try:
            vm = next((m for m in view.view if m.name == vm_name), None)
        finally:
            view.Destroy()
        if vm is None:
            sys.exit("set-vapp-descriptors: VM %r not found" % vm_name)

        vapp = vm.config.vAppConfig
        existing = {p.id: p for p in (vapp.property if vapp else [])}
        missing = [d[0] for d in DESCRIPTORS if d[0] not in existing]
        if missing:
            sys.exit("set-vapp-descriptors: VM lacks expected properties: %s"
                     % ", ".join(missing))

        # Keys are immutable and drive the wizard's ordering, so remove the
        # randomly-keyed properties and re-add them with ascending keys in
        # DESCRIPTORS order, starting past the current maximum to avoid any
        # remove/add key collision within one reconfigure.
        base = max((p.key for p in existing.values()), default=-1) + 1
        specs = [
            vim.vApp.PropertySpec(operation="remove", removeKey=prop.key)
            for prop in existing.values()
        ]
        for offset, (prop_id, category, label, description) in \
                enumerate(DESCRIPTORS):
            specs.append(vim.vApp.PropertySpec(
                operation="add",
                info=vim.vApp.PropertyInfo(
                    key=base + offset,
                    id=prop_id,
                    category=category,
                    label=label,
                    description=description,
                    type="string",
                    userConfigurable=True,
                    value=existing[prop_id].value or "",
                )))

        WaitForTask(vm.ReconfigVM_Task(
            spec=vim.vm.ConfigSpec(
                vAppConfig=vim.vApp.VmConfigSpec(property=specs))))
        print("set-vapp-descriptors: categorized, labeled and ordered %d"
              " deploy-form properties on %s" % (len(DESCRIPTORS), vm_name))
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
