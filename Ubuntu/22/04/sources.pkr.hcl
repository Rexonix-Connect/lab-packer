source "vsphere-iso" "base" {

  CPUs                 = var.cpuCount
  RAM                  = var.memoryMb
  disk_controller_type = ["pvscsi"]
  guest_os_type        = "ubuntu64Guest"

  # ISO configuration
  iso_checksum = ""
  iso_paths    = ["${var.isoPath}"]

  cd_content = {
    "/meta-data" = file("./files/meta-data")
    "/user-data" = templatefile("./files/user-data", {
      minimum_kmod_version   = var.minimumKmodVersion
      minimum_kernel_version = var.minimumKernelVersion
      vm_password_hash       = var.vmPasswordHash
    })
  }
  cd_label = "CIDATA"

  network_adapters {
    network      = "${var.portGroup}"
    network_card = "vmxnet3"
  }

  # Deploy-time form: userConfigurable OVF properties consumed by cloud-init
  # (DataSourceOVF) / Cloudbase-Init (OvfService) at first boot. Empty values
  # mean DHCP/SLAAC and no personalization. The plugin also enables the
  # com.vmware.guestInfo and iso OVF-environment transports.
  vapp {
    properties = {
      "hostname"       = ""
      "public-keys"    = ""
      "password"       = ""
      "user-data"      = ""
      "network.ip4"    = ""
      "network.gw4"    = ""
      "network.ip6"    = ""
      "network.gw6"    = ""
      "network.dns"    = ""
      "network.domain" = ""
    }
  }

  # Export to content library
  content_library_destination {
    name    = "${var.templateName}"
    library = "${var.libraryName}"
    ovf     = true
    destroy = true
  }

  # Communicator configuration
  communicator = "ssh"
  ssh_username = "${var.vmUsername}"
  ssh_password = "${var.vmPassword}"
  ssh_timeout  = var.sshTimeout

  boot_order = "disk,cdrom,floppy"
  boot_wait  = "3s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud\"",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]
  shutdown_command = "sudo -n -E /tmp/packer-finalize-template.sh"
  shutdown_timeout = "15m"

  configuration_parameters = {
    "disk.EnableUUID" = "true"
  }
}