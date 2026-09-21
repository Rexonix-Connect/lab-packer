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
  # the guest needs it. Docker's data root is moved onto it before any image is
  # pulled, so the pulled images land on the data disk rather than the root.
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

  # Everything that stays in the image: the first-boot bootstrap, the vendored
  # compose project, systemd units, nginx and fail2ban configuration and the
  # operator CLIs. Installed by the scripts below, never executed from /tmp.
  # No trailing slash on the source, so the directory itself lands in /tmp
  # rather than its contents landing in a directory scp would have to create.
  provisioner "file" {
    source      = "./files/diode-appliance"
    destination = "/tmp"
  }

  # Shared appliance Python installed into every image in this repository.
  # It is uploaded separately rather than copied into the payload because it
  # is genuinely shared: one copy in the repository, read by both appliances'
  # first-boot scripts, so the rules in it cannot drift between them.
  provisioner "file" {
    source      = "../../shared/appliance"
    destination = "/tmp"
  }

  # The seeded build account has NOPASSWD sudo, so unlike the ISO builds no
  # password is piped into sudo here.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "DIODE_VERSION=${var.diodeVersion}",
      "AGENT_VERSION=${var.agentVersion}",
      "BUILD_USERNAME=${var.buildUsername}",
      "PAYLOAD_DIR=/tmp/diode-appliance",
      "SHARED_DIR=/tmp/appliance",
    ]
    scripts = [
      "./files/wait-for-base.sh",
      # The appliance clones an already-built base, so it inherits that
      # image's kernel command line and cannot wait for the base to be
      # rebuilt to get a working datasource list.
      "../../shared/scripts/unpin-cloud-init-datasource.sh",
      "./files/install-datadisk.sh",
      "./files/install-packages.sh",
      # Before install-diode.sh: this moves Docker's data root onto the data
      # disk, and every image pulled afterwards has to land there.
      "./files/install-docker.sh",
      # Before install-diode.sh for the same reason the NetBox build validates
      # nginx early: a bad directive should fail in four minutes, not after
      # several gigabytes of image pulls.
      "./files/install-nginx.sh",
      "./files/install-diode.sh",
      "./files/install-agent.sh",
      "./files/install-ops.sh",
      "./files/install-firstboot.sh",
    ]
  }

  # Proves the stack actually comes up before it can become a template, then
  # re-asserts the hardened baseline and cleans the guest.
  provisioner "shell" {
    execute_command = "{{.Vars}} sudo -n -E bash '{{.Path}}'"
    environment_vars = [
      "DIODE_VERSION=${var.diodeVersion}",
      "AGENT_VERSION=${var.agentVersion}",
      "BUILD_USERNAME=${var.buildUsername}",
    ]
    scripts           = ["./files/verify.sh"]
    expect_disconnect = true
  }

  # The vapp block only sets ids and values; enrich the deploy form with
  # categories, labels, descriptions and ordering before the export. The Diode
  # properties do not exist on the cloned VM yet, so the descriptor file both
  # creates and documents them.
  provisioner "shell-local" {
    environment_vars = [
      "VCENTER_SERVER=${var.vCenterServer}",
      "VCENTER_USERNAME=${var.vCenterUsername}",
      "VCENTER_PASSWORD=${var.vCenterPassword}",
      "VCENTER_INSECURE=${var.vCenterInsecureConnection}",
      "VCENTER_DATACENTER=${var.vCenterDatacenterName}",
      "VM_NAME=${var.vmName}",
      "VAPP_EXTRA_DESCRIPTORS=../../shared/vapp-descriptors/netbox-diode.json",
    ]
    command = "python3 ../../shared/scripts/set-vapp-descriptors.py"
  }
}
