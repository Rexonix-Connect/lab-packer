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

  provisioner "file" {
    source      = "./files/cloudbase-init.conf"
    destination = "C:/Windows/Temp/cloudbase-init.conf"
  }

  provisioner "file" {
    source      = "./files/ovf-identity.ps1"
    destination = "C:/Windows/Temp/ovf-identity.ps1"
  }

  provisioner "file" {
    source      = "./files/ovf-network.ps1"
    destination = "C:/Windows/Temp/ovf-network.ps1"
  }

  provisioner "powershell" {
    environment_vars = ["CLOUDBASE_INIT_VERSION=${var.cloudbaseInitVersion}"]
    scripts          = ["./files/install-cloudbase-init.ps1"]
  }

  provisioner "powershell" {
    scripts = ["./files/harden.ps1"]
  }

  provisioner "powershell" {
    environment_vars = ["MINIMUM_TOOLS_VERSION=${var.minimumToolsVersion}"]
    scripts          = ["./files/setup.ps1"]
  }

  provisioner "file" {
    source      = "./files/finalize.ps1"
    destination = "C:/Windows/Temp/packer-finalize-template.ps1"
  }

  provisioner "file" {
    source      = "./files/finalize-deferred.ps1"
    destination = "C:/Windows/Temp/packer-finalize-deferred.ps1"
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
    command = "python3 ../../shared/scripts/set-vapp-descriptors.py"
  }
}
