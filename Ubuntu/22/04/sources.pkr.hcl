source "vsphere-iso" "base" {

  CPUs                  = 2
  RAM                   = 4096
  disk_controller_type  = ["pvscsi"]
  guest_os_type         = "ubuntu64Guest"

  # ISO configuration
  iso_checksum  = ""
  iso_paths     = ["${var.isoPath}"]

  cd_content            = {
    "/meta-data" = file("./files/meta-data")
    "/user-data" = file("./files/user-data")
  }
  cd_label = "cidata"

  network_adapters {
    network       = "${var.portGroup}"
    network_card  = "vmxnet3"
  }

  # Export to content library
  content_library_destination {
    name    = "${var.templateName}"
    library = "${var.libraryName}"
    ovf     = true
    destroy = true
  }

  # Communicator configuration
  communicator  = "ssh"
  ssh_username  = "${var.vmUsername}"
  ssh_password  = "${var.vmPassword}"
  ssh_timeout   = "30m"
  # ssh_handshake_attempts = "10000"

  boot_order            = "disk,cdrom,floppy"
  boot_wait             = "3s"
  boot_command = [
      "c<wait>",
      "linux /casper/vmlinuz --- autoinstall ds=\"nocloud-net\"",
      "<enter><wait>",
      "initrd /casper/initrd",
      "<enter><wait>",
      "boot",
      "<enter>"
      ]
  shutdown_command      = "echo '${var.vmPassword}' | sudo -S -E shutdown -P now"
  shutdown_timeout      = "15m"

  configuration_parameters = {
    "disk.EnableUUID" = "true"
  }
}