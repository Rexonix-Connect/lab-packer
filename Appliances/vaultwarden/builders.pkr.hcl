build {
  source "source.vsphere-clone.base" {

    # Connection configuration
    vcenter_server      = "${var.vCenterServer}"
    username            = "${var.vCenterUsername}"
    password            = "${var.vCenterPassword}"
    insecure_connection = var.vCenterInsecureConnection
    datacenter          = "${var.vCenterDatacenterName}"

    # Location configuration
    vm_name   = "${var.vmName}"
    folder    = "${var.vmFolder}"
    cluster   = "${var.clusterName}"
    datastore = "${var.datastoreName}"
  }

  # The data disk at SCSI 0:1, attached while the build VM runs - the plugin
  # rejects a storage block for an OVF-backed content library source.
  provisioner "shell-local" {
    environment_vars = [
      "VCENTER_SERVER=${var.vCenterServer}",
      "VCENTER_USERNAME=${var.vCenterUsername}",
      "VCENTER_PASSWORD=${var.vCenterPassword}",
      "VCENTER_INSECURE=${var.vCenterInsecureConnection}",
      "VCENTER_DATACENTER=${var.vCenterDatacenterName}",
      "VM_NAME=${var.vmName}",
      "DISK_SIZE_GB=${var.dataDiskGb}",
    ]
    command = "python3 ../../shared/scripts/add-vm-disk.py"
  }

  provisioner "file" {
    source      = "./files/finalize.sh"
    destination = "/tmp/packer-finalize-template.sh"
  }

  # Everything that stays in the image: the bootstrap, the guard, the Compose
  # project, systemd units, nginx and fail2ban configuration and the operator
  # CLIs. No trailing slash, so the directory itself lands in /tmp.
  provisioner "file" {
    source      = "./files/vaultwarden-appliance"
    destination = "/tmp"
  }

  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "VAULTWARDEN_VERSION=${var.vaultwardenVersion}",
      "VAULTWARDEN_IMAGE=${var.vaultwardenImageRepository}:${var.vaultwardenVersion}@${var.vaultwardenImageDigest}",
      "BUILD_USERNAME=${var.buildUsername}",
      "PAYLOAD_DIR=/tmp/vaultwarden-appliance",
    ]
    scripts = [
      "./files/wait-for-base.sh",
      "../../shared/scripts/unpin-cloud-init-datasource.sh",
      "./files/install-datadisk.sh",
      "./files/install-packages.sh",
      "./files/install-postgresql.sh",
      # Before Vaultwarden on purpose, as in the NetBox build: nginx -t is a
      # quick failure, and nothing in it depends on the container existing.
      "./files/install-nginx.sh",
      "./files/install-docker.sh",
      "./files/install-vaultwarden.sh",
      "./files/install-ops.sh",
      "./files/install-firstboot.sh",
    ]
  }

  # Proves the appliance serves Vaultwarden end to end, re-asserts the
  # hardened baseline and the network exposure, then cleans the guest.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "VAULTWARDEN_VERSION=${var.vaultwardenVersion}",
      "BUILD_USERNAME=${var.buildUsername}",
    ]
    scripts           = ["./files/verify.sh"]
    expect_disconnect = true
  }

  # Everything finalize.sh (the shutdown command, whose output Packer never
  # shows) does not strictly have to do: a failure here is visible in the
  # build log instead of being a silent 20-minute shutdown timeout.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "BUILD_USERNAME=${var.buildUsername}",
    ]
    scripts = ["./files/finalize-prepare.sh"]
  }

  # Categories, labels, descriptions and ordering for the deploy form, plus the
  # vaultwarden.* properties themselves, which the cloned VM does not have yet.
  provisioner "shell-local" {
    environment_vars = [
      "VCENTER_SERVER=${var.vCenterServer}",
      "VCENTER_USERNAME=${var.vCenterUsername}",
      "VCENTER_PASSWORD=${var.vCenterPassword}",
      "VCENTER_INSECURE=${var.vCenterInsecureConnection}",
      "VCENTER_DATACENTER=${var.vCenterDatacenterName}",
      "VM_NAME=${var.vmName}",
      "VAPP_EXTRA_DESCRIPTORS=../../shared/vapp-descriptors/vaultwarden.json",
    ]
    command = "python3 ../../shared/scripts/set-vapp-descriptors.py"
  }
}
