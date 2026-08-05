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
      install_desktop        = var.installDesktop
    })
  }
  cd_label = "CIDATA"

  network_adapters {
    network      = "${var.portGroup}"
    network_card = "vmxnet3"
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