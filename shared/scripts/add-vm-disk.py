#!/usr/bin/env python3
"""Attach an extra thin-provisioned disk to a build VM.

The vsphere-clone builder cannot do this itself for an OVF-backed content
library source: packer-plugin-vsphere rejects the configuration outright with
"'storage' cannot be used with OVF content library items". So an image that
needs a data disk asks vCenter for one directly, as a shell-local provisioner,
while the build VM is running.

The disk is attached to the VM's existing SCSI controller at a fixed unit
number, which gives the guest a deterministic /dev/disk/by-path/*-scsi-<bus>:0:
<unit>:0 to find it by rather than guessing at device names. Re-running is a
no-op: if the unit is already occupied the script reports and exits cleanly, so
a retried build does not stack disks.
"""
import argparse
import importlib.util
import os
import ssl
import sys

from pyVim.connect import Disconnect, SmartConnect
from pyVim.task import WaitForTask
from pyVmomi import vim

# find_vm lives with the other provisioner that reconfigures build VMs; import
# it rather than keeping a second copy of the inventory lookup.
_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "set_vapp_descriptors", os.path.join(_HERE, "set-vapp-descriptors.py"))
_descriptors_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_descriptors_module)
find_vm = _descriptors_module.find_vm


def env(name):
    value = os.environ.get(name, "")
    if not value:
        sys.exit("add-vm-disk: %s is not set" % name)
    return value


def scsi_controller(vm, bus_number):
    for device in vm.config.hardware.device:
        if isinstance(device, vim.vm.device.VirtualSCSIController) \
                and device.busNumber == bus_number:
            return device
    return None


def disks_on(vm, controller):
    return [device for device in vm.config.hardware.device
            if isinstance(device, vim.vm.device.VirtualDisk)
            and device.controllerKey == controller.key]


def next_device_key(vm):
    # Negative keys mark devices being added in this reconfigure; vCenter
    # assigns the real key. Staying below the current minimum avoids colliding
    # with anything already present.
    lowest = min((device.key for device in vm.config.hardware.device),
                 default=0)
    return min(-101, lowest - 1)


def build_disk_spec(vm, controller, unit_number, size_kb):
    backing = vim.vm.device.VirtualDisk.FlatVer2BackingInfo(
        diskMode="persistent",
        thinProvisioned=True,
        # An empty file name asks vCenter to place the VMDK alongside the VM,
        # on the datastore the clone already landed on.
        fileName="",
    )
    disk = vim.vm.device.VirtualDisk(
        key=next_device_key(vm),
        backing=backing,
        controllerKey=controller.key,
        unitNumber=unit_number,
        capacityInKB=size_kb,
    )
    return vim.vm.device.VirtualDeviceSpec(
        operation=vim.vm.device.VirtualDeviceSpec.Operation.add,
        fileOperation=vim.vm.device.VirtualDeviceSpec.FileOperation.create,
        device=disk,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="report the controller and unit that would be"
                             " used, without changing the VM")
    arguments = parser.parse_args()

    host = env("VCENTER_SERVER")
    username = env("VCENTER_USERNAME")
    password = env("VCENTER_PASSWORD")
    vm_name = env("VM_NAME")
    size_gb = int(env("DISK_SIZE_GB"))
    bus_number = int(os.environ.get("DISK_SCSI_BUS", "0"))
    unit_number = int(os.environ.get("DISK_SCSI_UNIT", "1"))
    datacenter = os.environ.get("VCENTER_DATACENTER", "")
    insecure = os.environ.get("VCENTER_INSECURE", "false").lower() == "true"

    if size_gb <= 0:
        sys.exit("add-vm-disk: DISK_SIZE_GB must be a positive number of GB")
    # Unit 7 is reserved for the controller itself on a SCSI bus.
    if unit_number == 7 or not 0 <= unit_number <= 15:
        sys.exit("add-vm-disk: DISK_SCSI_UNIT must be 0-15 and not 7")

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
            sys.exit("add-vm-disk: VM %r not found" % vm_name)

        controller = scsi_controller(vm, bus_number)
        if controller is None:
            sys.exit("add-vm-disk: VM %r has no SCSI controller on bus %d"
                     % (vm_name, bus_number))

        occupied = {disk.unitNumber: disk for disk in disks_on(vm, controller)}
        if unit_number in occupied:
            existing = occupied[unit_number]
            print("add-vm-disk: %s already has a disk at %d:%d (%d GB);"
                  " leaving it alone"
                  % (vm_name, bus_number, unit_number,
                     existing.capacityInKB // (1024 * 1024)))
            return

        if arguments.dry_run:
            print("add-vm-disk: would attach a %d GB thin disk to %s at"
                  " %d:%d (controller key %d)"
                  % (size_gb, vm_name, bus_number, unit_number,
                     controller.key))
            return

        spec = vim.vm.ConfigSpec(deviceChange=[
            build_disk_spec(vm, controller, unit_number,
                            size_gb * 1024 * 1024),
        ])
        WaitForTask(vm.ReconfigVM_Task(spec=spec))
        print("add-vm-disk: attached a %d GB thin disk to %s at %d:%d"
              % (size_gb, vm_name, bus_number, unit_number))
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
