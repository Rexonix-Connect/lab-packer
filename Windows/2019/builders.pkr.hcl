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
    # The generated CD carries the plaintext build credentials, so strip all
    # CD-ROM devices from the template.
    remove_cdrom = true
  }

  # Patch the template with every applicable non-preview update so clones
  # start with known vulnerabilities fixed.
  provisioner "windows-update" {
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
  }

  provisioner "powershell" {
    scripts = ["./files/setup.ps1"]
  }

  provisioner "file" {
    source      = "./files/finalize.ps1"
    destination = "C:/Windows/Temp/packer-finalize-template.ps1"
  }
}
