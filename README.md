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
  - `VCENTER_INSECURE_CONNECTION` - whether to allow insecure connection to the vCenter Server, e.g. `true` or `false`
