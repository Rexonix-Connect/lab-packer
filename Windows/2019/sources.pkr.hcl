source "vsphere-iso" "base" {

  CPUs                 = var.cpuCount
  RAM                  = var.memoryMb
  firmware             = "efi-secure"
  disk_controller_type = ["pvscsi"]
  guest_os_type        = "windows2019srv_64Guest"

  # ISO configuration: the Windows ISO plus the ESXi host's bundled VMware
  # Tools ISO. WinPE loads the pvscsi driver from the tools ISO (E:) and the
  # first-logon script installs the full tools, bringing up the vmxnet3
  # driver, before Packer connects over WinRM.
  iso_checksum = ""
  iso_paths = [
    "${var.isoPath}",
    "${var.toolsIsoPath}",
  ]

  cd_content = {
    "/autounattend.xml" = templatefile("./files/autounattend.pkrtpl.xml", {
      vm_username         = var.vmUsername
      vm_password         = var.vmPassword
      windows_image_index = var.windowsImageIndex
      windows_product_key = var.windowsProductKey
      windows_language    = var.windowsLanguage
      windows_timezone    = var.windowsTimezone
    })
    "/windows-vmtools.ps1" = file("./files/windows-vmtools.ps1")
    "/windows-init.ps1"    = file("./files/windows-init.ps1")
  }

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
      "username"       = ""
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
  communicator   = "winrm"
  winrm_username = "${var.vmUsername}"
  winrm_password = "${var.vmPassword}"
  winrm_timeout  = var.winrmTimeout

  boot_order = "disk,cdrom"
  boot_wait  = "2s"
  # Answers the "Press any key to boot from CD or DVD" prompt.
  boot_command = ["<spacebar>"]
  # The finalize script uploaded by the file provisioner hardens the guest and
  # powers it off.
  shutdown_command = "powershell -ExecutionPolicy Bypass -File C:/Windows/Temp/packer-finalize-template.ps1"
  shutdown_timeout = "15m"

  configuration_parameters = {
    "disk.EnableUUID" = "true"
  }
}
