source "vsphere-clone" "base" {

  # Source configuration: the published hardened Ubuntu 24.04 server library
  # item, exactly as the NetBox appliance does it. An OVF-backed content
  # library source inherits the base's firmware, disk layout, virtual hardware
  # version and hardening; the plugin rejects disk_size, storage and
  # disk_controller_type for this source type, so the 60 GB root disk comes
  # across as-is and the data disk is attached through the vCenter API
  # instead (see builders.pkr.hcl).
  content_library_source {
    library = "${var.libraryName}"
    name    = "${var.sourceTemplateName}"
  }

  CPUs     = var.cpuCount
  RAM      = var.memoryMb
  firmware = var.firmware

  # OVF library items declare a network that has to be mapped at deploy time;
  # the plugin fails the build if this is missing.
  network = "${var.portGroup}"

  # Build-time SSH bootstrap. The hardened base deletes its provisioning
  # account, disables SSH password authentication and strips its host keys, so
  # a clone has nothing to log into. A NoCloud seed creates a throwaway
  # key-only account instead; finalize.sh removes it again and the CD is
  # detached before the export.
  cd_content = {
    "/meta-data" = file("./files/cloud-init-meta-data")
    "/user-data" = templatefile("./files/cloud-init-user-data", {
      build_username   = var.buildUsername
      build_public_key = var.buildPublicKey
    })
  }
  cd_label     = "CIDATA"
  remove_cdrom = true

  # No vapp block on purpose: vCenter rejects any id the source OVF does not
  # declare. The eleven inherited properties come across with the clone and the
  # Vaultwarden ones are added by set-vapp-descriptors.py before the export.

  # Export to content library
  content_library_destination {
    name    = "${var.templateName}"
    library = "${var.libraryName}"
    ovf     = true
    destroy = true
  }

  # Communicator configuration
  communicator         = "ssh"
  ssh_username         = "${var.buildUsername}"
  ssh_private_key_file = "${var.buildPrivateKeyFile}"
  ssh_timeout          = var.sshTimeout
  ip_wait_timeout      = var.ipWaitTimeout

  # The provisioners' environment_vars do not reach this separate session, so
  # the account to delete is passed explicitly; finalize.sh also falls back
  # to SUDO_USER, which is that account whichever name it was given.
  shutdown_command = "sudo -n env BUILD_USERNAME=${var.buildUsername} /tmp/packer-finalize-template.sh"
  shutdown_timeout = "20m"

  configuration_parameters = {
    "disk.EnableUUID" = "true"
  }
}
