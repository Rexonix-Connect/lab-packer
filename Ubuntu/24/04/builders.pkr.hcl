build {
  source "source.vsphere-iso.base" {

    # Connection configuration
    vcenter_server      = "${var.vCenterServer}"
    username            = "${var.vCenterUsername}"
    password            = "${var.vCenterPassword}"
    insecure_connection = var.vCenterInsecureConnection
    datacenter          = "${var.vCenterDatacenterName}"

    # Disk configuration
    storage {
      disk_size             = var.diskSizeGb * 1024
      disk_thin_provisioned = true
    }

    # Location configuration
    vm_name   = "${var.vmName}"
    folder    = "${var.vmFolder}"
    cluster   = "${var.clusterName}"
    datastore = "${var.datastoreName}"
    # Remove all cdroms except first
    reattach_cdroms = 1
  }

  provisioner "file" {
    source      = "./files/finalize.sh"
    destination = "/tmp/packer-finalize-template.sh"
  }

  provisioner "shell" {
    execute_command = "echo '${var.vmPassword}' | {{.Vars}} sudo -S -E bash '{{.Path}}'"
    environment_vars = [
      "INSTALL_DESKTOP=${var.installDesktop}",
    ]
    scripts = ["./files/install-desktop.sh"]
  }

  provisioner "shell" {
    execute_command = "echo '${var.vmPassword}' | {{.Vars}} sudo -S -E bash '{{.Path}}'"
    environment_vars = [
      "BUILD_USERNAME=${var.vmUsername}",
    ]
    scripts           = ["./files/setup.sh"]
    expect_disconnect = true
  }
}
