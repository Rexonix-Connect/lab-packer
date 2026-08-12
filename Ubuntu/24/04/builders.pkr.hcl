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
    scripts = [
      "../../../shared/scripts/unpin-cloud-init-datasource.sh",
      "./files/setup.sh",
    ]
    expect_disconnect = true
  }
  # The vapp block only sets ids and values; enrich the deploy form with
  # categories, labels, descriptions and ordering before the export.
  provisioner "shell-local" {
    environment_vars = [
      "VCENTER_SERVER=${var.vCenterServer}",
      "VCENTER_USERNAME=${var.vCenterUsername}",
      "VCENTER_PASSWORD=${var.vCenterPassword}",
      "VCENTER_INSECURE=${var.vCenterInsecureConnection}",
      "VCENTER_DATACENTER=${var.vCenterDatacenterName}",
      "VM_NAME=${var.vmName}",
    ]
    command = "python3 ../../../shared/scripts/set-vapp-descriptors.py"
  }
}
