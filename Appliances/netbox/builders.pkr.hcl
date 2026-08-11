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

  # The data disk cannot be declared in the source block - the plugin rejects a
  # storage block for an OVF-backed content library source - so it is attached
  # through the vCenter API while the build VM is running, before anything in
  # the guest needs it.
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

  # Everything that stays in the image: the first-boot bootstrap, the NetBox
  # configuration loader, systemd units, nginx and fail2ban configuration and
  # the operator CLIs. Installed by the scripts below, never executed from
  # /tmp. No trailing slash on the source, so the directory itself lands in
  # /tmp rather than its contents landing in a directory scp would have to
  # create.
  provisioner "file" {
    source      = "./files/netbox-appliance"
    destination = "/tmp"
  }

  # The seeded build account has NOPASSWD sudo, so unlike the ISO builds no
  # password is piped into sudo here.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "NETBOX_VERSION=${var.netboxVersion}",
      "NETBOX_REPO_URL=${var.netboxRepoUrl}",
      "BUILD_USERNAME=${var.buildUsername}",
      "PAYLOAD_DIR=/tmp/netbox-appliance",
    ]
    scripts = [
      "./files/wait-for-base.sh",
      "./files/install-datadisk.sh",
      "./files/install-packages.sh",
      "./files/install-netbox.sh",
      "./files/install-nginx.sh",
      "./files/install-ops.sh",
      "./files/install-firstboot.sh",
    ]
  }

  # Proves the appliance actually serves NetBox before it can become a
  # template, then re-asserts the hardened baseline and cleans the guest.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "NETBOX_VERSION=${var.netboxVersion}",
      "BUILD_USERNAME=${var.buildUsername}",
    ]
    scripts           = ["./files/verify.sh"]
    expect_disconnect = true
  }

  # The vapp block only sets ids and values; enrich the deploy form with
  # categories, labels, descriptions and ordering before the export. The
  # NetBox properties do not exist on the cloned VM yet, so the descriptor
  # file both creates and documents them.
  provisioner "shell-local" {
    environment_vars = [
      "VCENTER_SERVER=${var.vCenterServer}",
      "VCENTER_USERNAME=${var.vCenterUsername}",
      "VCENTER_PASSWORD=${var.vCenterPassword}",
      "VCENTER_INSECURE=${var.vCenterInsecureConnection}",
      "VCENTER_DATACENTER=${var.vCenterDatacenterName}",
      "VM_NAME=${var.vmName}",
      "VAPP_EXTRA_DESCRIPTORS=../../shared/vapp-descriptors/netbox.json",
    ]
    command = "python3 ../../shared/scripts/set-vapp-descriptors.py"
  }
}
