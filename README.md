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
  - `RECOVERY_PASSWORD` - password for the permanent `recovery` console break-glass account baked into the Ubuntu templates (hashed at build time; see "Deploying the templates")

#### Ubuntu template hardening

The Ubuntu 22.04 template build applies a small security baseline during autoinstall and final cleanup:

- Installs `unattended-upgrades` and `open-vm-tools` for ongoing security patching and vSphere guest integration, and explicitly enables periodic unattended security upgrades (`/etc/apt/apt.conf.d/20auto-upgrades`) so clones keep patching known vulnerabilities on their own.
- Enforces minimum package versions that fix the known CVEs listed below (`kmod`, kernel) and fails the build otherwise.
- Disables direct root SSH login in the generated template.
- Bakes a `recovery` sudo user (password from the `RECOVERY_PASSWORD` secret) as console break-glass: because SSH password authentication is disabled, the password only works on the hypervisor console, so a clone whose first-boot configuration fails is still reachable.
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

### Test VM Templates

[![Test VM Templates](../../actions/workflows/test_vm_templates.yml/badge.svg)](../../actions/workflows/test_vm_templates.yml)

Smoke-tests all six VM templates currently in the content library: for each template (Ubuntu 22.04/24.04 server and desktop, Windows Server 2019/2022) a matrix job deploys a test VM named `testvm-<template>-<run id>`, powers it on, and verifies the guest actually works — VMware Tools comes up, the guest obtains an IP address within the timeout, and the guest hostname is reported. The VM is then kept running for an inspection window before being deleted; deletion also runs when a verification step fails, so no test VMs are left behind (raise `keep_minutes` if you want more time to inspect a failure via the console).

The checks are deliberately credential-free (templates ship with the provisioning account removed or disabled): a booted guest with running tools and DHCP networking is the template's health signal. The `govc` CLI (pinned release, downloaded at run time) performs all vCenter operations, using the same repository variables and secrets as the build workflows, including all six `*_VM_TEMPLATE_NAME` variables. On a single self-hosted runner the six matrix jobs execute one after another.

#### Workflow inputs

- `keep_minutes` - minutes to keep each test VM running before deletion; defaults to `10`
- `ip_timeout` - how long to wait for VMware Tools to report an IP address, e.g. `15m`; defaults to `15m`

### Build Windows Server 2019 / 2022 VM Templates

[![Build Windows Server 2019 VM Template](../../actions/workflows/build_windows_server_2019_vm_template.yml/badge.svg)](../../actions/workflows/build_windows_server_2019_vm_template.yml)
[![Build Windows Server 2022 VM Template](../../actions/workflows/build_windows_server_2022_vm_template.yml/badge.svg)](../../actions/workflows/build_windows_server_2022_vm_template.yml)

The Windows builds boot the installation ISO together with the ESXi host's bundled VMware Tools ISO (`/vmimages/tools-isoimages/windows.iso`, present on ESXi by default): Windows Setup loads the `pvscsi` driver from the tools ISO, and a first-logon script installs the full VMware Tools (bringing up the `vmxnet3` driver) and enables WinRM for the Packer communicator. VMs run UEFI with Secure Boot, 4 vCPU / 8192 MB, and a 90 GB thin disk by default.

#### Workflow inputs

- `disk_size_gb` - optional numeric disk size for the VM template in GB, minimum `60`; defaults to `90`
- `winrm_timeout` - optional Packer WinRM wait timeout covering the unattended install and first-logon tools installation, e.g. `2h` or `3h`; defaults to `2h`

#### Windows template requirements

Uses the same vCenter variables and secrets as the Ubuntu template workflows, plus:

- `WINDOWS_SERVER_2019_X64_ISO_PATH` / `WINDOWS_SERVER_2022_X64_ISO_PATH` - path to the Windows Server ISO in the vCenter datastore
- `WINDOWS_SERVER_2019_X64_VM_TEMPLATE_NAME` / `WINDOWS_SERVER_2022_X64_VM_TEMPLATE_NAME` - name of the VM template to create

Notes:

- The `PACKER_VM_PASSWORD` secret is interpolated into `autounattend.xml`, so it must not contain the XML special characters `&`, `<`, `>`, `'` or `"`.
- The default `windowsImageIndex` of `2` selects Standard (Desktop Experience) on standard Microsoft ISOs (`1` Standard Core, `3` Datacenter Core, `4` Datacenter Desktop Experience).
- Without `windowsProductKey` set, evaluation media installs normally and licensed media prompts activation later; for volume licensing set the appropriate key or a public Microsoft KMS client setup key (GVLK).

#### Windows template hardening

- The `windows-update` Packer provisioner installs every applicable non-preview update during the build, and the verification step fails the build if any software update is still pending — templates ship with known vulnerabilities patched at build time.
- UAC stays enabled throughout: the build uses `LocalAccountTokenFilterPolicy` for the WinRM session instead of disabling LUA, and removes that policy again during finalize.
- Finalize removes autologon credentials and unattend answer files (including `C:\Windows\Panther` copies, which contain the build password) and cleans the update cache, temporary files and event logs. The session-hostile steps — re-hardening WinRM (no unencrypted transport, no basic authentication), removing `LocalAccountTokenFilterPolicy`, disabling the `vagrant` provisioning account (disabled rather than deleted; clone customization manages accounts) and the power-off — run from a detached one-shot SYSTEM scheduled task, because every WinRM request re-authenticates and changing WinRM auth or the build account from inside Packer's own session would sever it mid-shutdown. The task deletes the finalize scripts and itself before powering off, so nothing is left behind in the template.
- The generated answer-file CD carries the plaintext build credentials, so all CD-ROM devices are removed from the template (`remove_cdrom`).
- The build intentionally does not run Sysprep: vCenter guest customization specifications sysprep Windows clones at deployment, which is the supported path for template-based cloning.
- A pinned Cloudbase-Init (service account LocalSystem, automatic start) provides deploy-time personalization from the vApp property form (OVF ISO transport), NoCloud/ConfigDrive (non-VMware platforms), and VMware guestinfo metadata; when none of these has data — for example a clone deployed with a customization spec — the run idles and changes nothing.

### Build Ubuntu 22.04 / 24.04 Desktop VM Templates

[![Build Ubuntu 22.04 Desktop VM Template](../../actions/workflows/build_ubuntu_22_04_desktop_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_22_04_desktop_vm_template.yml)
[![Build Ubuntu 24.04 Desktop VM Template](../../actions/workflows/build_ubuntu_24_04_desktop_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_24_04_desktop_vm_template.yml)

The desktop workflows reuse the corresponding **server** build and ISO: the same autoinstall installs the server base, and with `installDesktop=true` a provisioning step then installs the `ubuntu-desktop^` task plus `open-vm-tools-desktop` over SSH on the booted system. This keeps one build mechanism for both flavors on both releases (on 22.04 the desktop ISO's Ubiquity installer has no autoinstall support at all, and on 24.04 it avoids maintaining a second autoinstall variant). The desktop task is deliberately not installed as an autoinstall late-command: its snap-backed packages need a running snapd, which does not exist in the installer chroot, and running it during provisioning keeps the multi-gigabyte download outside the SSH wait timeout with full apt output in the workflow log. All hardening, known-CVE mitigations, verification, and cleanup from the server templates apply unchanged.

#### Workflow inputs

- `disk_size_gb` - optional numeric disk size for the VM template in GB, minimum `25`, e.g. `100`; defaults to `60`
- `ssh_timeout` - optional Packer SSH communicator wait timeout, e.g. `45m` or `1h`; defaults to `45m` (the desktop task installs during provisioning, after SSH is up, so the wait matches the server build)

#### Ubuntu desktop template requirements

Uses the same variables and secrets as the matching server template workflow (including the **server** ISO path variable), plus:

- `UBUNTU_22_04_DESKTOP_X64_VM_TEMPLATE_NAME` / `UBUNTU_24_04_DESKTOP_X64_VM_TEMPLATE_NAME` - name of the desktop VM template to create, e.g. `ubuntu-22.04-desktop-x64-template`

#### Desktop template notes

- Desktop builds run with 4 vCPU / 8192 MB RAM (`cpuCount` / `memoryMb` variables; server builds keep 2 vCPU / 4096 MB).
- The installed system uses NetworkManager as the netplan renderer, which is the standard desktop networking stack; `cloud-init` remains installed from the server base for clone-time growpart and vSphere customization.
- On 24.04 desktop clones, revert `kernel.io_uring_disabled=2` from the sysctl baseline if a desktop workload needs io_uring; Ubuntu's browsers ship AppArmor profiles compatible with the user-namespace restriction.
- The Mesa Amber legacy-GPU packages (`libgl1-amber-dri`, `libglapi-amber`) are excluded from the desktop task: on amd64 they are uninstallable next to current Mesa (`libglapi-amber` Breaks `libglapi-mesa`), and they only serve pre-OpenGL-2.1 physical GPUs — VMware guests render through `vmwgfx` on current Mesa.

## Deploying the templates

### vApp deploy form (vSphere)

Every template's content library OVF item carries user-configurable OVF properties, so the vSphere "New VM from This Template" / "Deploy From Library" wizard shows a **Customize template** page. All fields default to empty, which means "leave as-is": DHCP/SLAAC networking and no personalization, identical to deploying before this feature existed.

| Property | Meaning |
| --- | --- |
| `hostname` | Guest hostname (Linux: cloud-init; Windows: Cloudbase-Init computer rename, reboots once) |
| `public-keys` | SSH public key(s) authorized for the default user (Linux) / Administrator (Windows) |
| `password` | Account password: Linux default-user password (cloud-init), Windows Administrator password |
| `user-data` | **base64-encoded** cloud-config (Linux) / Cloudbase-Init userdata (Windows) for anything beyond the basic fields |
| `network.ip4` | Static IPv4 address in CIDR form, e.g. `192.168.10.5/24`; empty = DHCP |
| `network.gw4` | IPv4 default gateway |
| `network.ip6` | Static IPv6 address in CIDR form, e.g. `2001:db8:1::5/64`; empty = SLAAC/router advertisements |
| `network.gw6` | IPv6 default gateway |
| `network.dns` | DNS servers, space or comma separated, IPv4 and IPv6 mixed freely |
| `network.domain` | DNS search domain(s) |

Consumption paths: on Linux the native fields are read by cloud-init's OVF datasource, and the `network.*` fields are applied by `/usr/local/sbin/ovf-network.py` (a systemd oneshot that runs before networking on every boot, so editing the properties and rebooting re-applies them; it writes `/etc/netplan/90-ovf.yaml` and never blocks boot on errors). On Windows, Cloudbase-Init's OvfService reads the same properties from the OVF environment ISO, and `ovf-network.ps1` (a Cloudbase-Init local script, run once per deployment) applies the `network.*` fields.

Precedence: explicitly injected `guestinfo.metadata`/`guestinfo.userdata` (e.g. from Terraform) outranks the form on Linux; vCenter guest customization specs continue to work unchanged on both OS families and are the right tool for bulk cloning.

### Non-VMware platforms

The same first-boot machinery works outside vSphere because the datasource lists are platform-portable (`NoCloud, ConfigDrive, VMware, OVF, None` on Linux; NoCloud + ConfigDrive services on Windows). On Proxmox VE, import the disk and attach a cloud-init drive: `citype=nocloud` for the Ubuntu templates, `citype=configdrive2` for the Windows templates (Proxmox defaults per ostype). The vApp form itself is vSphere-only — on other platforms supply the equivalent settings through the platform's cloud-init mechanism. `qemu-guest-agent` is not preinstalled; add it on KVM-based clones for IP reporting.

### Console recovery (break-glass)

- **Ubuntu**: log in on the hypervisor console as `recovery` with the `RECOVERY_PASSWORD` secret value (sudo-capable). SSH password authentication is disabled in the templates, so this password is useless over the network by design.
- **Windows**: log in on the console as `Administrator` with the `PACKER_VM_PASSWORD` secret value (or the value set via the form's `password` field at deploy time).

First-boot diagnostics: `cloud-init status --long` and `/var/log/cloud-init.log` (Linux), `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log` (Windows), and `journalctl -u ovf-network` for the network helper.
