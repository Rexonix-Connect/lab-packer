# lab-packer

VM template creation in vCenter with Hashicorp Packer using Self-hosted runners

## General Requirements

- Github Actions Runner, preferably self-hosted and X64 architecture, due to some Javascript based Github Actions
- Repository having access to the above runner
- vCenter Server with API access from the above runner

## Github Workflows

### Build Custom Packer Docker Image

[![Build Custom Packer Docker Image](../../actions/workflows/build_packer_image.yml/badge.svg)](../../actions/workflows/build_packer_image.yml)

#### Docker image requirements

- Variables accessible to the workflow:
  - `RUNNER_LABELS` - labels of the runner to use for the workflow, e.g. `["self-hosted", "X64"]`
  - `PACKER_DOCKER_IMAGE` - name of the custom Packer Docker image to build, e.g. `ghcr.io/username/packer`
  - `PACKER_DOCKER_IMAGE_TAG` - tag of the custom Packer Docker image to build, e.g. `latest`

### Build Ubuntu 22.04 Server VM Template

[![Build Ubuntu 22.04 Server VM #Template](../../actions/workflows/build_ubuntu_22_04_server_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_22_04_server_vm_template.yml)

#### Workflow inputs

- `disk_size_gb` - optional numeric disk size for the VM template in GB, minimum `25`, e.g. `100`; defaults to `60`
- `ssh_timeout` - optional Packer SSH communicator wait timeout, e.g. `45m` or `1h`; defaults to `45m`

#### Ubuntu template requirements

- Variables accessible to the workflow:
  - `RUNNER_LABELS` - labels of the runner to use for the workflow, e.g. `["self-hosted", "X64"]`
  - `PACKER_DOCKER_IMAGE` - name of the custom Packer Docker image to use for the workflow, e.g. `ghcr.io/username/packer`
  - `PACKER_DOCKER_IMAGE_TAG` - tag of the custom Packer Docker image to use for the workflow, e.g. `latest`
  - `VCENTER_DATACENTER_NAME` - name of the vCenter datacenter to use for the VM template, e.g. `Datacenter`
  - `VCENTER_CLUSTER_NAME` - name of the vCenter cluster to use for the VM template, e.g. `Cluster`
  - `VCENTER_DATASTORE_NAME` - name of the vCenter datastore to use for the VM template, e.g. `Datastore`
  - `UBUNTU_22_04_SERVER_X64_ISO_PATH` - path to the Ubuntu 22.04 Server x64 ISO in the vCenter datastore, e.g. `iso/ubuntu-22.04-server-x64.iso`
  - `UBUNTU_22_04_SERVER_X64_VM_TEMPLATE_NAME` - name of the Ubuntu 22.04 Server x64 VM template to create, e.g. `ubuntu-22.04-server-x64-template`
  - `VCENTER_PACKER_CONTENT_LIBRARY_NAME` - name of the vCenter content library to use for the VM template, e.g. `PackerContentLibrary`
  - `VCENTER_DEFAULT_PORT_GROUP` - name of the vCenter port group to use for the VM template, e.g. `VM Network`
- Secrets accessible to the workflow:
  - `VCENTER_HOST` - FQDN or IP address of the vCenter Server, e.g. `vcenter.example.com`
  - `VCENTER_USER` - username to authenticate to the vCenter Server, e.g. `administrator@vsphere.local`
  - `VCENTER_PASS` - password to authenticate to the vCenter Server, e.g. `supersecretpassword`
  - `VCENTER_INSECURE_CONNECTION` - whether to allow insecure connection to the vCenter Server, e.g. `true` or `false`; prefer `false` and install the trusted vCenter CA on the runner/container where possible

#### Ubuntu template hardening

The Ubuntu 22.04 template build applies a small security baseline during autoinstall and final cleanup:

- Uses the HTTPS Ubuntu apt mirror configured in `Ubuntu/22/04/files/user-data`.
- Keeps Subiquity's default progress output enabled, attempts a best-effort raw installer log stream to `/dev/console`, and dumps installer log tails to the console on failure.
- Installs `unattended-upgrades` and `open-vm-tools` for ongoing security patching and vSphere guest integration.
- Disables direct root SSH login in the generated template.
- Removes `sshpass` from the guest package list and custom Packer container image.
- Cleans apt lists, temporary files, shell histories, cloud-init logs/seeds, SSH host keys, and machine identity data before templating.
- Runs `packer fmt -check` and `packer validate` in the Ubuntu template workflow before starting the vSphere build.

##### CVE-2026-31431 Copy Fail mitigation

Ubuntu 22.04 Jammy is affected by CVE-2026-31431, also known as Copy Fail. The build requires `kmod` version `29-1ubuntu1.1` or newer and writes a modprobe rule that blocks the vulnerable `algif_aead` kernel module:

- `/etc/modprobe.d/manual-disable-algif_aead.conf`
- `install algif_aead /bin/false`
- `blacklist algif_aead`

The final cleanup script fails the build if `algif_aead` is not blocked or if it is loaded. This mitigation can affect workloads that require this kernel crypto module, so test crypto-heavy or container workloads before using the template broadly.

To verify a built VM, check that `kmod` is at least `29-1ubuntu1.1`, `modprobe -n -v algif_aead` resolves to `/bin/false`, and `algif_aead` is absent from `/proc/modules`.

##### Current SSH model

The workflow still uses the temporary `vagrant` account and password-based Packer communicator during provisioning. Root SSH login is disabled, but moving the Packer communicator to SSH keys and removing the persistent `vagrant` password remains the next hardening step.
