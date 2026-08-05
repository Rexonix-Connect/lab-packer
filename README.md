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

[![Build Ubuntu 22.04 Server VM Template](../../actions/workflows/build_ubuntu_22_04_server_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_22_04_server_vm_template.yml)

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
  - `PACKER_VM_PASSWORD` - password for the temporary `vagrant` provisioning account used by the Packer SSH communicator; the account is removed during the final template shutdown step

#### Ubuntu template hardening

The Ubuntu 22.04 template build applies a small security baseline during autoinstall and final cleanup:

- Installs `unattended-upgrades` and `open-vm-tools` for ongoing security patching and vSphere guest integration, and explicitly enables periodic unattended security upgrades (`/etc/apt/apt.conf.d/20auto-upgrades`) so clones keep patching known vulnerabilities on their own.
- Enforces minimum package versions that fix the known CVEs listed below (`kmod`, kernel) and fails the build otherwise.
- Disables direct root SSH login in the generated template.
- Disables SSH password authentication during final template cleanup.
- Enables `ufw` with default-deny inbound and SSH explicitly allowed, so every clone starts with an active firewall.
- Cleans apt lists, temporary files, shell histories, cloud-init logs/seeds, SSH host keys, and machine identity data before templating.

##### Known-CVE kernel mitigations

The build mitigates the 2026 Linux kernel local privilege escalation family following the Ubuntu Security Team guidance for each advisory. Every module below is blocked via `install <module> /bin/false` plus `blacklist <module>` in `/etc/modprobe.d/manual-disable-<name>.conf`, the initramfs is regenerated so the blocks apply from early boot, and the build fails if any module is not blocked or is loaded at templating time:

- `algif_aead` — CVE-2026-31431 "Copy Fail" (AF_ALG AEAD crypto interface); also requires `kmod` >= `29-1ubuntu1.1`, which ships Ubuntu's own mitigation.
- `act_pedit` — CVE-2026-46331 "pedit COW" (tc-pedit traffic control action).
- `esp4`, `esp6` — CVE-2026-46300 "Fragnesia", CVE-2026-43284 "Dirty Frag", CVE-2026-43503 "DirtyClone" (IPsec ESP).
- `rxrpc` — CVE-2026-43500 "Dirty Frag", CVE-2026-43503 "DirtyClone" (RxRPC/AFS).

Independently of the module blocks, the build asserts that the installed kernel is at least `5.15.0-181.191`, the version that fixes all of the above plus CVE-2026-46333 "ssh-keysign-pwn", so the CVEs stay fixed even on clones that re-enable a blocked module.

Caveats: blocking `esp4`/`esp6` breaks in-guest IPsec (for example StrongSwan VPN labs), `rxrpc` breaks AFS, `act_pedit` breaks tc-pedit rules, and `algif_aead` can affect crypto-heavy workloads. To re-enable a module on a clone that needs it, delete the matching `/etc/modprobe.d/manual-disable-<name>.conf`, run `update-initramfs -u`, and reboot — the enforced kernel minimum keeps the underlying CVEs patched.

The template also ships `/etc/sysctl.d/zz-lab-hardening.conf` (named to apply after Ubuntu's unnumbered `protect-links.conf`, which would otherwise reset `fs.protected_fifos` to `1`) reducing common exploitation surface (`kernel.dmesg_restrict=1`, `kernel.kptr_restrict=1`, `kernel.yama.ptrace_scope=1`, `kernel.unprivileged_bpf_disabled=2`, `net.core.bpf_jit_harden=2`, `fs.protected_fifos=2`, `fs.protected_regular=2`). The cleanup script verifies the live values, the module blocks, and that periodic unattended upgrades are enabled, and fails the build on any mismatch.

To verify a built VM: `kmod` >= `29-1ubuntu1.1`, newest installed `linux-image-*` >= `5.15.0-181.191`, `modprobe -n -v <module>` resolves to `/bin/false` for each blocked module, none of them appear in `/proc/modules`, and `sysctl kernel.dmesg_restrict` reports `1`.

##### Vagrant provisioning account

The build uses a temporary `vagrant` account and password-based Packer SSH communicator during provisioning. During the final shutdown step, SSH password authentication is disabled and the `vagrant` account is removed from the template. The account password is stored as the `PACKER_VM_PASSWORD` repository secret and is not present in plaintext in any workflow file. Root SSH login is disabled.

### Build Ubuntu 24.04 Server VM Template

[![Build Ubuntu 24.04 Server VM Template](../../actions/workflows/build_ubuntu_24_04_server_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_24_04_server_vm_template.yml)

#### Workflow inputs

- `disk_size_gb` - optional numeric disk size for the VM template in GB, minimum `25`, e.g. `100`; defaults to `60`
- `ssh_timeout` - optional Packer SSH communicator wait timeout, e.g. `45m` or `1h`; defaults to `45m`

#### Ubuntu 24.04 template requirements

Uses the same variables and secrets as the Ubuntu 22.04 template workflow, except:

- `UBUNTU_24_04_SERVER_X64_ISO_PATH` - path to the Ubuntu 24.04 Server x64 ISO in the vCenter datastore, e.g. `iso/ubuntu-24.04-server-x64.iso`
- `UBUNTU_24_04_SERVER_X64_VM_TEMPLATE_NAME` - name of the Ubuntu 24.04 Server x64 VM template to create, e.g. `ubuntu-24.04-server-x64-template`

#### Ubuntu 24.04 template hardening

Applies the same security baseline, known-CVE kernel module mitigations, verification steps, and temporary `vagrant` account handling as the Ubuntu 22.04 template, with Noble-specific values and additions:

- Minimum `kmod` version `31+20240202-2ubuntu7.2` (Noble's CVE-2026-31431 "Copy Fail" mitigation release).
- Minimum kernel version `6.8.0-124.124`, the Noble release fixing the same 2026 LPE family listed in the 22.04 section.
- Two additional sysctl baseline entries available on Noble's 6.8 kernel: `kernel.io_uring_disabled=2` (io_uring has been a recurring local privilege escalation source; re-enable on clones whose workloads need it) and `kernel.apparmor_restrict_unprivileged_userns=1` (asserts Noble's default AppArmor confinement of unprivileged user namespaces stays active).
- Because Noble uses deb822 apt sources (`ubuntu.sources`), the installer-time security-pocket disable is undone by re-appending the `noble-security` stanza rather than un-commenting `sources.list` lines.
