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
- Asserts `snapd` and `open-vm-tools` are fully patched at build time — rather than a brittle version literal, the build fails if the local apt cache still offers a newer version, so the setuid-root `snap-confine` LPE (CVE-2026-8933, USN-8579-1) and the VMware guest-tools advisories are covered — and refreshes seeded snaps (`snap refresh`, best-effort) so the `snapd` snap and any seeded apps ship current instead of at ISO vintage.
- Cleans apt lists, temporary files, shell histories, cloud-init logs/seeds, SSH host keys, and machine identity data before templating.

The deploy-form managed user is placed in `adm, cdrom, dip, plugdev, sudo` — deliberately **not** `lxd`, whose membership is documented root-equivalence and redundant next to `sudo`.

`apport` is disabled (`/etc/default/apport` `enabled=0`): its boot script otherwise forces `fs.suid_dumpable=2` on every boot regardless of sysctl ([LP #1452239](https://bugs.launchpad.net/bugs/1452239)), so the `fs.suid_dumpable=0` in the sysctl baseline only holds with apport off; apport is a crash reporter with no purpose on a template.

##### Known-CVE kernel mitigations

The build mitigates the 2026 Linux kernel local privilege escalation family following the Ubuntu Security Team guidance for each advisory. Every module below is blocked via `install <module> /bin/false` plus `blacklist <module>` in `/etc/modprobe.d/manual-disable-<name>.conf`, the initramfs is regenerated so the blocks apply from early boot, and the build fails if any module is not blocked or is loaded at templating time:

- `algif_aead` — CVE-2026-31431 "Copy Fail" (AF_ALG AEAD crypto interface); also requires `kmod` >= `29-1ubuntu1.1`, which ships Ubuntu's own mitigation.
- `act_pedit` — CVE-2026-46331 "pedit COW" (tc-pedit traffic control action).
- `esp4`, `esp6` — CVE-2026-46300 "Fragnesia", CVE-2026-43284 "Dirty Frag", CVE-2026-43503 "DirtyClone" (IPsec ESP).
- `rxrpc` — CVE-2026-43500 "Dirty Frag", CVE-2026-43503 "DirtyClone" (RxRPC/AFS).

Independently of the module blocks, the build asserts that the installed kernel is at least `5.15.0-181.191`, the version that fixes all of the above plus CVE-2026-46333 "ssh-keysign-pwn", so the CVEs stay fixed even on clones that re-enable a blocked module.

Caveats: blocking `esp4`/`esp6` breaks in-guest IPsec (for example StrongSwan VPN labs), `rxrpc` breaks AFS, `act_pedit` breaks tc-pedit rules, and `algif_aead` can affect crypto-heavy workloads. To re-enable a module on a clone that needs it, delete the matching `/etc/modprobe.d/manual-disable-<name>.conf`, run `update-initramfs -u`, and reboot — the enforced kernel minimum keeps the underlying CVEs patched.

The template also ships `/etc/sysctl.d/zz-lab-hardening.conf` (named to apply after Ubuntu's unnumbered `protect-links.conf`, which would otherwise reset `fs.protected_fifos` to `1`) reducing common exploitation surface. Kernel/fs keys: `kernel.dmesg_restrict=1`, `kernel.kptr_restrict=1`, `kernel.yama.ptrace_scope=1`, `kernel.unprivileged_bpf_disabled=2`, `net.core.bpf_jit_harden=2`, `fs.protected_fifos=2`, `fs.protected_regular=2`, `fs.suid_dumpable=0` (24.04 additionally sets `kernel.io_uring_disabled=2` and `kernel.apparmor_restrict_unprivileged_userns=1`, which require the 6.8 kernel). Network keys, applied to a VM that is not a router so they carry no functional cost: ICMP redirects refused and not sent (`net.ipv4.conf.{all,default}.{accept,secure,send}_redirects=0`, `net.ipv6.conf.{all,default}.accept_redirects=0`), source routing refused (`accept_source_route=0`, v4 and v6), martian logging on, and broadcast/bogus-ICMP responses ignored. The cleanup script verifies a representative subset of live values, the module blocks, and that periodic unattended upgrades are enabled, and fails the build on any mismatch.

To verify a built VM: `kmod` >= `29-1ubuntu1.1`, newest installed `linux-image-*` >= `5.15.0-181.191`, `modprobe -n -v <module>` resolves to `/bin/false` for each blocked module, none of them appear in `/proc/modules`, and `sysctl kernel.dmesg_restrict` reports `1`.

##### Vagrant provisioning account

The build uses a temporary `vagrant` account and password-based Packer SSH communicator during provisioning. During the final shutdown step, SSH password authentication is disabled and the `vagrant` account is removed from the template. The account password is stored as the `PACKER_VM_PASSWORD` repository secret and is not present in plaintext in any workflow file. Root SSH login is disabled.

> **Both halves of that used to be untrue, and templates built before this fix ship a working `vagrant` password login.** `finalize.sh` ran `userdel -r vagrant || true` from the shutdown command — over `vagrant`'s own SSH session, so `userdel` refused ("currently used by process N") and `|| true` swallowed it. And `PasswordAuthentication no` went to the bottom of `/etc/ssh/sshd_config`, but sshd takes the **first** value it obtains for a keyword and the `Include sshd_config.d/*.conf` line sits near the top — so cloud-init's `50-cloud-init.conf`, which enables password auth because the build needs it, won. Removal now falls back to `userdel -f -r` and **fails the build** if the account survives; the directive moved to `00-no-password-auth.conf`, which sorts ahead of cloud-init's file, and `sshd -T` asserts the effective value before export. Rebuild every template to clear it. The NetBox appliance purges both from the base it clones, so it does not need the base rebuilt first.

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

Smoke-tests the VM templates in the content library: for each selected template a test VM named `testvm-<template>-<run id>` is deployed, powered on, and checked for whether the guest actually works — VMware Tools comes up, the guest obtains an IP address within the timeout, and the guest hostname is reported.

**One workflow per template.** Each template has its own workflow — `Test Ubuntu 24.04 Server`, `Test NetBox Appliance` and so on — runnable on its own from the Actions tab, because what is worth checking diverges sharply between an OS template and an appliance. This workflow is the umbrella over them: it keeps one checkbox per template, all ticked by default, and calls the individual workflows. Untick the rest to re-test a single image after a fix instead of sitting through the other seven on a single self-hosted runner. Unticking everything fails the run rather than reporting success for a run that tested nothing.

The shared VM lifecycle lives in composite actions under `.github/actions/` — `deploy-test-vm`, `verify-guest-boot`, `collect-vm-diagnostics`, `cleanup-test-vm` — so the per-template workflows carry only their own assertions rather than eight copies of the same deploy-and-destroy code.

The checks themselves need no credentials — templates ship with the provisioning account removed or disabled, and a booted guest with running tools and DHCP networking is the template's health signal. The `govc` CLI (pinned release, downloaded at run time) performs all vCenter operations, using the same repository variables and secrets as the build workflows, including all eight `*_VM_TEMPLATE_NAME` variables. On a single self-hosted runner the jobs execute one after another.

**Every Linux guest must prove it booted cleanly** before any template-specific check runs. Before power-on a throwaway `diag` account is seeded through the VMware guestinfo datasource (a per-run ed25519 key that never leaves the runner, authorizing an account that only exists on a VM about to be deleted). Then:

- **The login itself must succeed.** The account is created by cloud-init from guestinfo user-data — the same channel the vApp deploy form uses — so failing to log in means deploy-time configuration is not reaching the guest at all. This is a failure, not a warning.
- **cloud-init must reach `done`**, within a bounded wait. `cloud-init status --wait` is deliberately run under `timeout`: a guest whose `cloud-final.service` job was dropped sits at `running` for the life of the machine, and an unbounded wait would hang instead of reporting it.
- **The journal must contain no ordering cycle.** systemd breaks a dependency cycle by *deleting* start jobs, and the units it deletes log nothing at all — no failure, no message, nothing under `systemctl status`. Grepping the journal is the only way to see it from outside.

These run before the template-specific checks so a guest that never finished booting fails here, with a reason, rather than twenty minutes later as an HTTP timeout.

**On failure, a Linux guest is asked what went wrong.** It logs in and dumps the boot and service state into the workflow log in collapsible sections: dependency cycles and pending jobs first, then failed units, and for the NetBox appliance `/var/lib/netbox-appliance/failed` where the first-boot bootstrap writes its full traceback, the `netbox-bootstrap` journal, cloud-init status, the `/srv/netbox` mount, the listening sockets and the nginx error log. `collect_diagnostics` turns off both the seeding and the boot checks together.

**A failed test keeps its VM, and the login for it.** Successful and cancelled runs delete both; a failure leaves the VM running and keeps the `diag` key on the runner, printing the `ssh` line to reach it and the `govc vm.destroy` line to clean up. The seeded account has a locked password and the templates ship with their provisioning account removed or disabled, so discarding that key would leave the evidence intact and unreachable. Set `destroy_on_failure` to delete regardless. Test VM names carry the run *attempt* as well as the run id, so re-running a failed job does not collide with the VM it kept.

The NetBox appliance gets three extra checks, because "the VM booted" is a much weaker claim for an appliance than for an OS template: every `netbox.*` deploy-form property must be present, both disks must have survived the export and deploy, and — deployed with a completely empty form — it must serve its login page over HTTPS (200), redirect plain HTTP (301), reject an unauthenticated API call (403) and deny `/metrics` (403, since no allowlist was deployed). The certificate it generated for itself is printed. Turn the HTTP half off with `netbox_http_check` if the runner cannot reach the VM network.

#### Workflow inputs

- `test_<template>` - one checkbox per template (`test_ubuntu_22_04_server`, `test_ubuntu_22_04_desktop`, `test_ubuntu_24_04_server`, `test_ubuntu_24_04_desktop`, `test_ubuntu_24_04_server_hardened`, `test_netbox_appliance`, `test_windows_server_2019`, `test_windows_server_2022`); all default to `true`
- `keep_minutes` - minutes to keep each **successful** test VM running before deletion; defaults to `0`. Failures keep their VM regardless, so this only pads runs that passed
- `ip_timeout` - how long to wait for VMware Tools to report an IP address, e.g. `15m`; defaults to `15m`
- `netbox_http_check` - check that the NetBox appliance actually serves HTTPS; defaults to `true`, turn it off when the runner has no route to the VM network
- `collect_diagnostics` - seed a login on Linux guests, check they booted cleanly, and dump their state on failure; defaults to `true`
- `destroy_on_failure` - delete the test VM even when the test fails; defaults to `false`
- `netbox_timeout_minutes` - minutes to wait for the appliance's first-boot bootstrap before failing; defaults to `20`

The per-template workflows take the same inputs, minus the `test_<template>` checkboxes, and the `netbox_*` ones only where they apply.

### Rebuild All VM Templates

[![Rebuild All VM Templates](../../actions/workflows/rebuild_all_vm_templates.yml/badge.svg)](../../actions/workflows/rebuild_all_vm_templates.yml)

Rebuilds the selected templates **in sequence** — Ubuntu 22.04 server, 22.04 desktop, 24.04 server, 24.04 desktop, 24.04 server hardened, the NetBox appliance, Windows Server 2019, Windows Server 2022 — by calling the individual build workflows (which are also callable on their own via `workflow_call`). Each build uses its own workflow's default inputs. On a single self-hosted runner expect several hours end to end.

**Each template has its own checkbox**, all ticked by default, so a run rebuilds everything unless you say otherwise. The chain depends on the previous *build* rather than requiring it to have succeeded, so unticking a template skips it without stopping everything behind it.

**Each build is tested as soon as it finishes**, by calling that template's own test workflow, rather than all tests queueing behind the last build. A broken image is therefore reported close to when it was built instead of hours later, and a run that dies halfway still leaves the templates it did finish tested. A template whose build failed is not tested, since that would silently test the previous library item.

Whether a test overlaps the next build depends on runner capacity: a test job needs only its own build, so it is free to run alongside the next one, but on a single runner it queues instead. When it does overlap, one test VM exists while a build runs — fewer concurrent VMs than the old shape, which started all eight tests together at the end, though not literally unchanged load. The builds themselves stay strictly serialized either way.

The NetBox appliance is placed directly after the hardened template because it is *cloned from* that library item rather than installed from an ISO, so the order is a real dependency rather than a convention. With `continue_on_failure` it still runs after a failed hardened build — it then clones the previous hardened library item, which is deliberate: an appliance built on the last known-good base beats no appliance at all.

#### Workflow inputs

- `rebuild_<template>` - one checkbox per template (`rebuild_ubuntu_22_04_server`, `rebuild_ubuntu_22_04_desktop`, `rebuild_ubuntu_24_04_server`, `rebuild_ubuntu_24_04_desktop`, `rebuild_ubuntu_24_04_server_hardened`, `rebuild_netbox_appliance`, `rebuild_windows_server_2019`, `rebuild_windows_server_2022`); all default to `true`
- `continue_on_failure` - keep rebuilding the remaining templates when one build fails (the failed template's old library item stays in place); defaults to `false`, which stops the chain at the first failure
- `run_tests` - test each template as soon as it is built; defaults to `true`
- `keep_minutes`, `collect_diagnostics`, `destroy_on_failure` - passed through to every template's test
- `netbox_timeout_minutes` - passed to the NetBox appliance test only; no other template's test accepts it

GitHub's documentation gives `workflow_dispatch` a maximum of ten inputs, but that is not enforced in practice — `test_vm_templates.yml` carries fourteen and dispatches normally. This workflow stops at fourteen for the same reason: fourteen is what is demonstrably known to work here. `ip_timeout` and `netbox_http_check` are the two left out; run a single template's test workflow to set those.

The test flow additionally verifies on every deployed test VM that the vApp deploy form schema (all `hostname`/`username`/`network.*`/… properties) survived the OVF export/deploy chain, warning instead of failing for templates built before the deploy form existed.

### Normalize Deploy Form

[![Normalize Deploy Form](../../actions/workflows/normalize_deploy_form.yml/badge.svg)](../../actions/workflows/normalize_deploy_form.yml)

Reruns the post-build deploy-form normalization (`shared/scripts/normalize-library-ovf.py`, see "vApp deploy form") on an existing content library item, given its `template_name` — useful for templates exported while the normalize step was broken or before it existed, without spending a rebuild. Signed library items (`.cert` present) are refused.

#### Workflow inputs

- `template_name` - the content library item to normalize; required
- `extra_descriptors` - the deploy-form extension the item was built with, for application-layer images: `none` (default, the eleven shared properties) or `netbox`. Getting this wrong is not silent — the normalizer refuses to run when it cannot find every property it expects.

### Build Windows Server 2019 / 2022 VM Templates

[![Build Windows Server 2019 VM Template](../../actions/workflows/build_windows_server_2019_vm_template.yml/badge.svg)](../../actions/workflows/build_windows_server_2019_vm_template.yml)
[![Build Windows Server 2022 VM Template](../../actions/workflows/build_windows_server_2022_vm_template.yml/badge.svg)](../../actions/workflows/build_windows_server_2022_vm_template.yml)

The Windows builds boot the installation ISO together with a VMware Tools ISO: Windows Setup loads the `pvscsi` driver from the tools ISO, and a first-logon script installs the full VMware Tools (bringing up the `vmxnet3` driver) and enables WinRM for the Packer communicator. VMs run UEFI with Secure Boot, 4 vCPU / 8192 MB, and a 90 GB thin disk by default.

By default the tools ISO is the ESXi host's bundled copy (`/vmimages/tools-isoimages/windows.iso`, present on ESXi), whose version tracks the host patch level. Set the `WINDOWS_TOOLS_ISO_PATH` repository variable to a pinned tools ISO uploaded to a datastore (e.g. `[datastore1] iso/VMware-Tools-windows-13.1.0.0-25218885.iso`) to control the Tools version independently of the host — download "VMware Tools packages for Windows" (the `...zip`) from Broadcom and extract the `.iso` from it. The build asserts the installed Tools version is at least `WINDOWS_MINIMUM_TOOLS_VERSION` (default `12.5.4`, the fixed release for the 2025-2026 Tools advisories) and fails otherwise.

#### Workflow inputs

- `disk_size_gb` - optional numeric disk size for the VM template in GB, minimum `60`; defaults to `90`
- `winrm_timeout` - optional Packer WinRM wait timeout covering the unattended install and first-logon tools installation, e.g. `2h` or `3h`; defaults to `2h`

#### Windows template requirements

Uses the same vCenter variables and secrets as the Ubuntu template workflows, plus:

- `WINDOWS_SERVER_2019_X64_ISO_PATH` / `WINDOWS_SERVER_2022_X64_ISO_PATH` - path to the Windows Server ISO in the vCenter datastore
- `WINDOWS_SERVER_2019_X64_VM_TEMPLATE_NAME` / `WINDOWS_SERVER_2022_X64_VM_TEMPLATE_NAME` - name of the VM template to create
- `WINDOWS_TOOLS_ISO_PATH` - optional datastore path to a pinned VMware Tools ISO; unset uses the ESXi host's bundled tools ISO
- `WINDOWS_MINIMUM_TOOLS_VERSION` - optional minimum acceptable installed VMware Tools version; defaults to `12.5.4`

Notes:

- The `PACKER_VM_PASSWORD` secret is interpolated into `autounattend.xml`, so it must not contain the XML special characters `&`, `<`, `>`, `'` or `"`.
- The default `windowsImageIndex` of `2` selects Standard (Desktop Experience) on standard Microsoft ISOs (`1` Standard Core, `3` Datacenter Core, `4` Datacenter Desktop Experience).
- Without `windowsProductKey` set, evaluation media installs normally and licensed media prompts activation later; for volume licensing set the appropriate key or a public Microsoft KMS client setup key (GVLK).

#### Windows template hardening

- The `windows-update` Packer provisioner installs every applicable non-preview update during the build, and the verification step fails the build if any software update is still pending — templates ship with known vulnerabilities patched at build time. Deployed clones keep patching themselves: the build sets Windows Update to auto-download and install on a schedule (`AUOptions=4`), since Windows Server does not self-install updates by default.
- `harden.ps1` applies a baseline of OS hardening the verification step then confirms (build fails if any did not take): SMB signing required on server and client and SMBv1 removed; NTLMv2-only auth with LM/NTLMv1 refused and no stored LM hash; WDigest cleartext credential caching off; LSA protection (`RunAsPPL`) enabling LSASS anti-tamper on the next boot; LLMNR and NetBIOS-over-TCP/IP name resolution disabled (responder/relay surface); Schannel limited to TLS 1.2+ with RC4/DES/3DES disabled; PowerShell script-block logging and a process-creation-with-command-line audit policy for visibility; and the Print Spooler disabled (PrintNightmare-class surface). Each is one registry value or service state and is listed here so a lab that needs the legacy behaviour can revert exactly that one — e.g. `Set-Service Spooler -StartupType Automatic` to print, or re-enabling TLS 1.0 for an ancient endpoint. NTLMv2 remains enabled, so WinRM (including Ansible-over-WinRM) against clones is unaffected.
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
- `cups-browsed` is removed after the desktop task installs: it is the network listener at the centre of the 2024 CUPS remote-code chain (CVE-2024-47176 and related). CUPS itself stays, so local and manually-added printers keep working; only automatic discovery of remote printers is lost (and `ufw` already blocks it inbound).

### Build Ubuntu 24.04 Server Hardened VM Template

[![Build Ubuntu 24.04 Server Hardened VM Template](../../actions/workflows/build_ubuntu_24_04_server_hardened_vm_template.yml/badge.svg)](../../actions/workflows/build_ubuntu_24_04_server_hardened_vm_template.yml)

A separate, more defensively-configured Ubuntu 24.04 **server** template (`Ubuntu/24/04-hardened/`), built from the same ISO as the standard 24.04 server template. It carries the full standard baseline (known-CVE module blocks, kernel/kmod floors, sysctl set including the network keys, `snapd`/`open-vm-tools` patch assertion, `ufw`, `recovery` break-glass user, deploy form) and adds:

- **UEFI Secure Boot** (`firmware = efi-secure`, parity with the Windows templates), which turns on kernel lockdown in integrity mode — asserted at build (as a warning, so a deliberate `firmware=bios`/`efi` fallback still builds). If a particular vSphere environment cannot boot the signed installer under Secure Boot, set the workflow's `firmware` input (or the `firmware` Packer variable) to `efi` or `bios`; the variable is validated to one of those three values.
- **auditd** with a curated ruleset (identity/sudoers/login file watches, time-change, module load/unload, and privileged-`execve` accounting).
- **SSH cryptographic hardening** written at finalize (after the build's own SSH session ends, so it can't break it): modern KEX/cipher/MAC allow-lists, `MaxAuthTries 4`, `LoginGraceTime 30`, no X11 forwarding, a pre-auth banner. TCP forwarding stays enabled for labs; password auth is disabled as on every template.
- **Extra module blocklist** for obsolete filesystems and rare network protocols (`cramfs`, `freevxfs`, `jffs2`, `hfs`, `hfsplus`, `dccp`, `sctp`, `rds`, `tipc`) — `squashfs`/`overlay` are deliberately kept, since snap and containers need them.
- **`/dev/shm` mounted `nodev,nosuid,noexec`**, core dumps disabled (`limits.d` + `systemd/coredump.conf.d`, alongside `fs.suid_dumpable=0`), and an authorized-use login banner.
- **`apport` disabled** (`/etc/default/apport` `enabled=0`): its boot script otherwise forces `fs.suid_dumpable=2` on every boot regardless of sysctl (LP #1452239), and it is a crash reporter with no purpose on a template — disabling it lets the `fs.suid_dumpable=0` setting hold.

Everything a normal 24.04 server clone does still works (cloud-init, the deploy form, snapd, `open-vm-tools`, unattended-upgrades). **Not** included, deliberately: separate `/var`, `/tmp`, `/home` partitions with per-mount options — that needs a custom autoinstall storage layout and a live build-test loop to get right, so it is left as a follow-up rather than shipped unverified. The build otherwise reuses the standard 24.04 server workflow structure and inputs.

Requirements: the same variables and secrets as the 24.04 server template (including its ISO path variable), plus `UBUNTU_24_04_SERVER_HARDENED_X64_VM_TEMPLATE_NAME` for the template name.

### Build NetBox Appliance VM Template

[![Build NetBox Appliance VM Template](../../actions/workflows/build_netbox_appliance_vm_template.yml/badge.svg)](../../actions/workflows/build_netbox_appliance_vm_template.yml)

A production-ready [NetBox](https://github.com/netbox-community/netbox) appliance (`Appliances/netbox/`): PostgreSQL, Redis, gunicorn, the RQ worker and nginx on one guest, deployable from the vSphere wizard and serving HTTPS a couple of minutes after power-on.

This is the first image in the repository that is **not** installed from an ISO. It uses the `vsphere-clone` builder with a `content_library_source`, so its source is the *published hardened 24.04 library item*. Everything that image guarantees — Secure Boot and kernel lockdown, the known-CVE module blocks, the sysctl baseline, auditd, the SSH crypto policy, unattended-upgrades, the `recovery` break-glass account and the deploy form — is inherited rather than reimplemented, and cannot drift. A build takes roughly ten to fifteen minutes instead of a full install, and **the hardened template must exist in the content library first**.

Cloning the hardened image poses one problem worth knowing about: it has no account to log in as, by design (it deletes its provisioning user, disables SSH password authentication and strips its host keys). The build therefore attaches a NoCloud `CIDATA` CD that creates a throwaway, key-only `pkrbuild` account, authorized by an ed25519 key pair the workflow generates per run and shreds afterwards. `finalize.sh` deletes the account, and the CD is detached before the export, so nothing of it reaches the template.

What is **baked into the template**: the OS packages, NetBox at the pinned tag on the data disk at `/srv/netbox`, reached through `/opt/netbox` (a full git history, so `netbox-upgrade` works later), the virtual environment with its pinned requirements, the collected static files, the bundled documentation, **and the already-migrated local database**. What is **generated per deployment**, on first boot: `SECRET_KEY`, the API token pepper, `ALLOWED_HOSTS`, the time zone, the TLS certificate, the superuser and the metrics allowlist.

Shipping a migrated database is safe here specifically because the local cluster authenticates by **peer over the Unix socket**, so the appliance has no database password to generate, bake, rotate or leak, and the template contains no user account — the superuser is created at deploy time. It buys a first boot of well under a minute and a template that bootstraps without reaching the network.

The build refuses to produce a template that does not work: `verify.sh` starts the whole stack and requires NetBox to answer its login page over HTTPS, plain HTTP to redirect, the API to reject anonymous callers, the reported version to match the requested tag, the service hardening drop-ins to be in effect, and the entire hardened baseline (module blocks, sysctls, `/dev/shm`, auditd, `recovery`) to still hold *after* the NetBox stack was installed on top.

#### Workflow inputs

- `netbox_version` - NetBox release tag to install; defaults to `v4.6.7`, validated against `vX.Y.Z`
- `ssh_timeout` - Packer SSH wait timeout; defaults to `45m`
- `firmware` - re-asserted on the clone so Secure Boot survives the export; **must match the firmware the hardened template was built with**, or the clone will not boot
- `cpu_count` / `memory_mb` - appliance sizing; default to `4` vCPU and `16384` MB, since the OS templates' 2/4096 is below what NetBox plus PostgreSQL needs
- `data_disk_gb` - size of the separate `/srv/netbox` data disk, minimum `50`; defaults to `150`

#### Disk layout

The appliance ships **two** disks:

| Mount | Size | Contents |
| --- | --- | --- |
| `/` | 60 GB (inherited) | The hardened base operating system |
| `/srv/netbox` | `data_disk_gb`, thin | NetBox and its virtual environment, the PostgreSQL cluster data directory, uploaded media, and `/srv/netbox/backups` |

The split exists so that the things which grow without bound — the database, media uploads and nightly backups — cannot fill the root filesystem. NetBox is installed at `/srv/netbox` with **`/opt/netbox` left as a symlink to it**, so upstream's systemd units, `gunicorn.py` and the nginx `alias` keep working against the path they hardcode; `upgrade.sh` derives its virtual environment from `pwd -P`, so the venv is created at the physical path either way. `/var/backups/netbox` is likewise a symlink to `/srv/netbox/backups`.

There is deliberately no `disk_size_gb` input for the **root** disk: the vSphere plugin does not honour disk resizing for an OVF-backed content library source, so the root comes across at the base's 60 GB. Enlarge it in the deploy wizard if you need to — the base image's `growpart`/`resize_rootfs` grow the root filesystem on first boot.

The data disk cannot be declared in the Packer source either, and for a blunter reason: `packer-plugin-vsphere` **rejects** a `storage` block outright for an OVF-backed content library item (`'storage' cannot be used with OVF content library items`). The build therefore attaches it through the vCenter API with `shared/scripts/add-vm-disk.py`, a `shell-local` provisioner that hot-adds a thin disk at SCSI 0:1 — a fixed unit number, so the guest can find it deterministically at `/dev/disk/by-path/*-scsi-*:0:1:0` rather than guessing at device names.

The filesystem is ext4 made on the **whole device, with no partition table**, and mounted from `/etc/fstab` by UUID with `nofail,nodev,nosuid`. That makes growing it a single `resize2fs` with no partition table to extend first: enlarge disk 2 in the deploy wizard and `netbox-datadisk.service` grows the filesystem on the next boot, with no manual step. `nofail` keeps a missing disk from dropping the VM into emergency mode, while `RequiresMountsFor=/srv/netbox` on the NetBox, nginx, bootstrap and PostgreSQL units means a missing disk leaves the appliance visibly down instead of quietly running on the root filesystem.

Requirements: the same vCenter variables and secrets as the other builds, plus `NETBOX_APPLIANCE_X64_VM_TEMPLATE_NAME` for the output template name and `UBUNTU_24_04_SERVER_HARDENED_X64_VM_TEMPLATE_NAME` for the **source** it clones. No ISO path, no `PACKER_VM_PASSWORD` and no `RECOVERY_PASSWORD` are needed — this build introduces no new secrets.

## Deploying the templates

### vApp deploy form (vSphere)

Every template's content library OVF item carries user-configurable OVF properties, so the vSphere "New VM from This Template" / "Deploy From Library" wizard shows a **Customize template** page with three sections in a fixed, logical order — **Guest Identity** (hostname, username, password, SSH keys), **Guest Network** (IPv4 pair, IPv6 pair, then DNS) and **Advanced** (user-data last) — with labeled and described fields, and the password input masked. Two build steps make this deterministic: a `shell-local` provisioner rewrites the property descriptors via pyvmomi before export (Packer's `vapp` block can only set ids and values; this requires `pyvmomi` in the Packer Docker image, so re-run "Build Custom Packer Docker Image" once before building templates with this change), and a post-build workflow step (`shared/scripts/normalize-library-ovf.py`) reorders the exported library OVF, because the vCenter export writes vApp properties in arbitrary order and the wizard renders document order. All fields default to empty, which means "leave as-is": DHCP/SLAAC networking and no personalization, identical to deploying before this feature existed.

| Property | Meaning |
| --- | --- |
| `hostname` | Guest hostname (Linux: cloud-init; Windows: Cloudbase-Init computer rename, reboots once) |
| `username` | Managed admin account: Linux renames the first-boot default user (default `ubuntu`); Windows creates it and adds it to `Administrators` — only when a password or SSH keys are also provided (default: the built-in `Administrator`); `password`/`public-keys` apply to this account; first boot only; reserved names (`root`, `vagrant`, `recovery`, `Administrator`) are ignored |
| `password` | Password for the managed account (masked in the wizard); empty never touches existing passwords |
| `public-keys` | SSH public key(s) for the managed account; **separate multiple keys with commas or new lines** (the wizard's field is single-line and strips pasted newlines, so commas are the reliable separator there; commas inside an options prefix like `from="a,b"` are handled) |
| `network.ip4` | Static IPv4 address in CIDR form, e.g. `192.168.10.5/24`; empty = DHCP |
| `network.gw4` | IPv4 default gateway |
| `network.ip6` | Static IPv6 address in CIDR form, e.g. `2001:db8:1::5/64`; empty = SLAAC/router advertisements |
| `network.gw6` | IPv6 default gateway |
| `network.dns` | DNS servers, space or comma separated, IPv4 and IPv6 mixed freely |
| `network.domain` | DNS search domain(s) |
| `user-data` | Advanced usage: **base64-encoded** cloud-config (Linux) / Cloudbase-Init userdata (Windows) for anything beyond the fields above |

The NetBox appliance carries the `netbox.*` properties on top, in the categories **NetBox Application**, **NetBox Network**, **NetBox TLS**, **NetBox Database** and **NetBox Cache**, placed before **Advanced**. Every one of them is optional: an entirely empty form produces a working, self-contained NetBox.

| Property | Meaning |
| --- | --- |
| `netbox.fqdn` | Name NetBox is reached by; drives `ALLOWED_HOSTS` and the certificate. Empty derives it from the guest hostname (qualified with `network.domain` when that is set) and the addresses held at first boot |
| `netbox.time-zone` | IANA time zone, e.g. `Europe/Prague`; empty means `UTC` |
| `netbox.admin-username` | Superuser created on first boot; empty means `admin` |
| `netbox.admin-email` | Superuser email; empty means `admin@example.com` |
| `netbox.admin-password` | Superuser password (masked in the wizard); **empty is the recommended value** — one is generated and shown on the VM console and in `/root/netbox-credentials.txt` |
| `netbox.metrics-allow` | Addresses/CIDRs allowed to scrape `/metrics` and `/node-metrics`; empty leaves Prometheus metrics and the node exporter switched off entirely |
| `netbox.tls-cert` | Base64-encoded PEM certificate chain for nginx; empty generates a self-signed certificate |
| `netbox.tls-key` | Base64-encoded PEM private key for the above; the pair is verified to match, and a mismatch fails the bootstrap rather than quietly serving self-signed |
| `netbox.db-host` | `host` or `host:port` of an external PostgreSQL 14+; empty uses the local cluster over its Unix socket |
| `netbox.db-name` / `netbox.db-user` | External database and role; both default to `netbox` |
| `netbox.db-password` | Password for the external role |
| `netbox.redis-host` | `host` or `host:port` of an external Redis 6+ (databases 0 and 1); empty uses the local Redis on loopback |
| `netbox.redis-password` | Password for the external Redis |

> **vApp property values are not a secret store.** They live in the VM's configuration in cleartext and are readable by anyone with read access to the VM in vCenter; `type="password"` only masks the *input field* in the deploy wizard. Prefer leaving `netbox.admin-password`, the database and Redis passwords and `netbox.tls-key` empty and taking the generated values from the appliance; when automation does need to supply them, clear the values in **Edit Settings → vApp Options** once the VM has booted.

Consumption paths: on Linux the native fields are read by cloud-init's OVF datasource, and the `network.*`, `username` and `public-keys` fields are applied by `/usr/local/sbin/ovf-settings.py` (a systemd oneshot that runs before networking on every boot, so editing the properties and rebooting re-applies them; it writes `/etc/netplan/90-ovf.yaml` plus a cloud-init user/keys override and never blocks boot on errors). On Windows, Cloudbase-Init's OvfService reads the same properties from the OVF environment ISO for hostname and user-data, while two local scripts (run once per deployment) apply the rest: `ovf-identity.ps1` handles username/password/public-keys deterministically — an empty password field never changes any password, keys land in `C:\ProgramData\ssh\administrators_authorized_keys` (correctly ACLed; OpenSSH Server is not preinstalled, the file takes effect once you enable it) — and `ovf-network.ps1` applies the `network.*` fields. The stock Cloudbase-Init user plugins are deliberately not used: they set a *random* password whenever the metadata carries none, which would silently break the Administrator break-glass on every form deployment.

Precedence: explicitly injected `guestinfo.metadata`/`guestinfo.userdata` (e.g. from Terraform) outranks the form on Linux; vCenter guest customization specs continue to work unchanged on both OS families and are the right tool for bulk cloning.

### Non-VMware platforms

> **`ds=` must never reach the installed kernel command line.** The ISO builds boot the installer with `autoinstall ds="nocloud"`, and casper appends everything after `---` to the *installed* system's command line. `ds=` does not mean "prefer this datasource" — cloud-init reads it as "use only this one", which overrides `datasource_list` entirely. Every template built before this was fixed came up pinned (`Kernel command line set to use a single datasource DataSourceNoCloud`, `seed=cmdline`), so VMware guestinfo and OVF were never consulted and nothing delivered through them — the deploy form's `user-data`, `public-keys` and `password`, or a guestinfo-seeded account — was applied. Only what `ovf-settings.py` reads out of the OVF environment itself got through, which is why networking worked and the rest silently did not. The boot commands now keep those parameters before `---`, and `shared/scripts/unpin-cloud-init-datasource.sh` strips any that survive, failing the build if it cannot. The appliance runs it too, since it clones an already-built base and cannot wait for that base to be rebuilt.

The same first-boot machinery works outside vSphere because the datasource lists are platform-portable (`NoCloud, ConfigDrive, VMware, OVF, None` on Linux; NoCloud + ConfigDrive services on Windows). On Proxmox VE, import the disk and attach a cloud-init drive: `citype=nocloud` for the Ubuntu templates, `citype=configdrive2` for the Windows templates (Proxmox defaults per ostype). The vApp form itself is vSphere-only — on other platforms supply the equivalent settings through the platform's cloud-init mechanism. `qemu-guest-agent` is not preinstalled; add it on KVM-based clones for IP reporting.

### Console recovery (break-glass)

- **Ubuntu**: log in on the hypervisor console as `recovery` with the `RECOVERY_PASSWORD` secret value (sudo-capable). SSH password authentication is disabled in the templates, so this password is useless over the network by design.
- **Windows**: log in on the console as `Administrator` with the `PACKER_VM_PASSWORD` secret value (or the value set via the form's `password` field at deploy time; leaving the field empty keeps the secret's value).

First-boot diagnostics: `cloud-init status --long` and `/var/log/cloud-init.log` (Linux), `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log` (Windows), and `journalctl -u ovf-settings` for the network helper.

## NetBox appliance operations

### First boot

**First boot takes several minutes.** `netbox-bootstrap.service` waits on `network-online.target` before `netbox-firstboot.py` starts at all, and the run itself migrates the database and creates the superuser. Until it finishes, `netbox-status` says `bootstrapping, not ready yet` and nothing is listening — expected rather than a fault. Afterwards it gains a `Serving` line taken from a loopback request to `/login/`, which is what catches an appliance whose units are up but which is not answering.

> **The appliance units must never be ordered after a late cloud-init unit.** `netbox-bootstrap.service` and `netbox-reconcile.service` are pulled into `multi-user.target`, and `cloud-final.service` is ordered *after* `multi-user.target`; adding `After=cloud-final.service` to either closes a dependency cycle. systemd does not report that as a failure — it breaks the cycle by **deleting jobs**, and the units whose jobs it deletes log nothing whatsoever. It dropped the bootstrap's start job, taking `nginx`, `netbox` and `netbox-rq` with it since they `Requires=` it, and it dropped `cloud-final.service` too, so cloud-init never finished and the deploy form stopped being applied. The appliance booted in thirteen seconds, reported no failed units, and served nothing. `install-firstboot.sh` now fails the build if either unit acquires such an ordering, and the test workflow greps every guest's journal for `ordering cycle`.
>
> Nothing is lost by leaving it out: cloud-init sets the host name and creates users in its **init** stage, which completes before `network-online.target`, and the deploy form's network and identity are applied earlier still by the base image's `ovf-settings.service`.
>
> If a deployed appliance is inert, `netbox-status` now says `BOOTSTRAP NEVER RAN` and points at `journalctl -b | grep -i 'ordering cycle'`.

`netbox-bootstrap.service` runs once, before `netbox`, `netbox-rq` and `nginx`, which all `Requires=` it. A failed bootstrap therefore leaves the appliance visibly down rather than serving a half-configured NetBox — `systemctl status netbox-bootstrap` is red, the MOTD says so, and the traceback is in `journalctl -u netbox-bootstrap -b` and `/var/lib/netbox-appliance/failed`. Fix the cause and re-run it with `systemctl start netbox-bootstrap`; it is idempotent.

It reads the deploy form through the base image's own `/usr/local/sbin/ovf-settings.py`, so there is no second OVF parser to keep in step. If the OVF environment is unavailable it fails open: every value falls back to a generated default and the appliance still comes up.

On every subsequent boot `netbox-reconcile.service` re-derives the host names and, if the certificate is one the appliance generated, reissues it when the addresses change. It never touches secrets, the database or the superuser — so cloning a *running* appliance gives you a working copy of it, which is what cloning a running system should mean.

### Changing the name it answers to

`netbox.fqdn` is a deploy-form property, but it is not read only at deploy time: `netbox-reconcile` re-reads the OVF environment on **every** boot and re-derives the appliance's identity from it. Changing the name is therefore a vCenter edit, not a login:

1. **Edit Settings → vApp Options → `netbox.fqdn`** on the VM, and point DNS at it.
2. **Power the VM off and on.** A guest `reboot` is not enough — the OVF environment the guest reads through VMware Tools is regenerated when vCenter powers the VM on, so a soft reboot re-runs the reconcile against the *old* values.

On that boot `netbox-reconcile` updates `ALLOWED_HOSTS` in `/etc/netbox/appliance.json`, rewrites nginx's `server_name`, reissues the certificate for the new name **if it is still the appliance's own**, updates the URL `netbox-status` reports, and restarts the services — all only if something actually changed. `journalctl -u netbox-reconcile -b` shows what it decided.

An operator-supplied certificate is never reissued, by design. If the new name falls outside what it covers, install one that does (`netbox-tls install`); a wildcard survives any name change inside its domain.

With `netbox.fqdn` empty the appliance falls back to the guest's own name (the form's `hostname`, qualified with `network.domain` when it is a bare label), and then to its first address — so `hostnamectl set-hostname netbox.example.com` also works when vCenter is out of reach, but only while the property is empty, because the property wins whenever it is set.

Editing `allowed_hosts` in `/etc/netbox/appliance.json` by hand is not durable: the next boot derives it again and overwrites it.

### Updating a deployed appliance

Three layers, and they do not want the same treatment.

**Ubuntu security patches** apply themselves: `unattended-upgrades` is enabled in the image. What the image does *not* do is reboot, so a kernel or libssl update installs and then sits inert until someone reboots. `netbox-status` reports both halves — pending security updates and whether a reboot is required — because on an appliance holding a database, choosing the reboot window is the operator's call, not the machine's.

It also reports **how long since the archive was last reached**. This matters more than it sounds: at a customer site the appliance may have no route out, or a proxy nobody told it about, and the failure is otherwise completely silent — the timer runs, finds nothing, and the appliance looks healthy while patching nothing for months. `LAST REACHED THE ARCHIVE 47 DAYS AGO` is the line that catches that.

**NetBox releases** use `netbox-upgrade vX.Y.Z`, which takes a backup first (migrations are not reversible), checks out the tag, runs NetBox's own `upgrade.sh`, restarts, verifies the appliance answers on 443, and prints the rollback commands. `--reinstall` rebuilds the virtual environment at the current tag, for when `local_requirements.txt` changed. Both need to reach GitHub and PyPI.

**Everything else — a NetBox major version, an Ubuntu release upgrade, a new appliance image — is a redeploy, not an upgrade.** Deploy the new template alongside, `netbox-restore` the most recent backup into it, verify, cut over, keep the old VM until you are sure. The appliance is built for this: the template carries no identity, the deploy form reconfigures everything at first boot, and `netbox-reconcile` re-derives host names and certificates when the address changes. In an air-gapped network this is the *only* upgrade path, since neither the archive nor PyPI is reachable.

#### Outbound proxy

Two deploy-form fields, `netbox.proxy` and `netbox.no-proxy`, point the appliance's own outbound traffic at a customer proxy. Without them a proxied site can never fetch Ubuntu security updates, a NetBox release or a plugin — and would do so silently, which is the failure `netbox-status` now surfaces.

The value is applied to the three places that actually need it, because none of them read the others: `/etc/environment` for login sessions (so `netbox-upgrade` and `netbox-plugin` inherit it), `/etc/apt/apt.conf.d/95netbox-proxy` for apt and `unattended-upgrades`, which are configured through `apt.conf` rather than the environment, and a systemd drop-in on `netbox.service` and `netbox-rq.service`, since a unit does not inherit `/etc/environment` and NetBox itself reaches out for webhooks, plugin scripts and custom reports.

It is re-applied on **every** boot, like the network settings: a customer's proxy can be introduced or changed after deployment, and clearing the field clears the proxy everywhere rather than leaving a stale one that quietly breaks patching. `localhost`, `127.0.0.1` and `::1` are always bypassed, plus whatever `netbox.no-proxy` lists.

The proxy URL must be `http://host[:port]` or `https://...`, optionally with `user:password@` — though prefer an unauthenticated proxy where possible: the apt configuration and the systemd drop-ins are written `0600`, and the journal only ever sees the URL with credentials redacted, but `/etc/environment` is world-readable by convention and necessity, so a credentialed URL there is visible to local accounts. Anything else is refused and logged rather than escaped — the value lands in an apt configuration string, a systemd `Environment=` line and `/etc/environment`, which quote differently, and a value that could terminate one of those strings is not worth escaping three ways. Bypass entries are filtered to plain hosts, domains and CIDRs on the same reasoning.

#### Plugins

Plugins are configuration, not file edits: `configuration.py` reads `PLUGINS` and `PLUGINS_CONFIG` out of `/etc/netbox/appliance.json`, and `netbox-reconcile` only ever rewrites `allowed_hosts`, so an operator's plugin set survives reboots and address changes untouched.

Use `netbox-plugin` rather than doing it by hand:

```
netbox-plugin list
netbox-plugin install netbox-bgp
netbox-plugin install 'netbox-topology-views==3.8.1'
netbox-plugin remove netbox_bgp
```

`install` adds the requirement, installs it, **resolves the module name from the installed distribution's own metadata**, enables it in `PLUGINS`, migrates, restarts and confirms the appliance still serves — reverting the configuration if it does not. That module-name step is the one worth having automated: the pip name and the module name routinely differ, and not by a rule you can guess (`PyYAML` provides `yaml`, not `pyyaml`). Putting the wrong one in `PLUGINS` gives you a NetBox that will not start.

`remove` disables the plugin and drops the requirement, but leaves its tables and data in the database — NetBox has no plugin uninstall that removes them, and dropping them by hand is how people lose data they meant to keep. Settings live under `plugins_config` in `appliance.json`.

`netbox-backup` captures both halves — `local_requirements.txt` and `appliance.json` — alongside the database, `netbox/media` (uploads and device-type images), `netbox/scripts` and `netbox/reports`, so **the plugin set is part of every backup**, and `netbox-restore` reinstalls the packages before it touches the database. If it cannot (no route to PyPI, or a plugin named in `PLUGINS` that `local_requirements.txt` does not install) it stops with the database untouched and says which plugin and why, rather than restoring and leaving an appliance that will not start.

Two things to plan for:

- **A NetBox upgrade can outrun a plugin.** Plugins declare a supported NetBox range, and a release that moves past it stops NetBox from starting. `netbox-upgrade` backs up first and verifies the appliance still answers on 443 afterwards, so a broken combination is caught immediately and it prints the rollback — but check your plugins' compatibility before upgrading, not after.
- **An air-gapped site cannot install plugins at all.** There is no route to PyPI, so the plugin set has to be baked into the image: put the requirements into `local_requirements.txt` during the build and rebuild the template. That is also the cleanest way to make a plugin set reproducible across many customers.

When something is wrong at a site you cannot reach, ask for `netbox-support-bundle`. It writes one reviewable tarball and states plainly that it contains no secrets, which is usually what the customer wants to know before sending it.

### Credentials

A generated admin password is written to `/root/netbox-credentials.txt` (mode 600) and echoed on the **local console** through `/etc/issue.d/60-netbox.issue`, because a freshly deployed appliance may have no other way in. It is deliberately never written to `/etc/issue.net`, which the hardened base uses as the pre-authentication SSH banner. After the first login:

```
netbox-manage changepassword admin
netbox-credentials --clear
```

### Day-two commands

All of them need root and live in `/usr/local/sbin`:

| Command | Purpose |
| --- | --- |
| `netbox-status` | Version, URL, database mode, TLS mode, service health, **whether it is actually serving** (a loopback request to `/login/`, which is a different question from whether systemd started the units), **patch state** (pending security updates, reboot required, and how long since the archive was last reached) and the last backup. Also drives the MOTD |
| `netbox-plugin` | `list`, `install <pip-requirement>`, `remove <module>`. Resolves the module name from the installed distribution's own metadata rather than guessing from the pip name, backs up first (enabling a plugin applies irreversible migrations), then migrates, restarts and verifies the appliance still serves — reverting the configuration if it does not |
| `netbox-support-bundle` | One tarball in `/var/tmp` with status, versions, patch state, unit state, journals, cloud-init, storage, listeners and the nginx log — for a site nobody outside can reach. `appliance.json` is redacted by key; the TLS private key and `/root/netbox-credentials.txt` are never read |
| `netbox-manage …` | Any NetBox management command inside the venv, as the `netbox` account (`netbox-manage nbshell`, `netbox-manage housekeeping`, `netbox-manage changepassword`) |
| `netbox-backup` | `pg_dump -Fc` plus a tarball of media, scripts, reports, `local_requirements.txt` and `/etc/netbox/appliance.json`, into `/srv/netbox/backups`. Runs nightly via `netbox-backup.timer`; retention is `RETENTION_DAYS` in `/etc/default/netbox-backup`, default 14 |
| `netbox-restore <timestamp>` | Restores a backup pair, applies any pending migrations, restarts and health-checks. Confirm-prompted |
| `netbox-upgrade <vX.Y.Z>` | Backs up, checks out the tag, runs `upgrade.sh`, restarts, health-checks, prints the rollback command. `--reinstall` rebuilds the venv at the current tag after editing `local_requirements.txt` |
| `netbox-credentials` | Print or `--clear` the generated credentials and the console banner |
| `netbox-tls` | `show` what certificate is installed, what it covers and when it expires; `install <cert> <key>` to replace it. The deploy form's TLS fields are first-boot only, so this is the day-two path for a real, wildcard or renewed certificate |

Backups contain `SECRET_KEY` and the API token pepper, so `/srv/netbox/backups` is `0700 root` and the archives are `0600`. That is deliberate: without them a restored database's API tokens and sessions cannot be validated. They archive **physical** `/srv/netbox/...` paths rather than `/opt/netbox/...`: extracting a member through a directory symlink makes `tar` replace that symlink with a real directory unless `--keep-directory-symlink` is given, which would quietly dismantle the `/opt/netbox` arrangement during a restore. Note also that backups living on the same disk as the data they protect are a convenience, not an off-box backup strategy.

NetBox's **housekeeping needs no cron entry** on this appliance. Since NetBox v4.4 it is a built-in daily system job executed by `netbox-rq`, so adding a timer would only run it twice; `netbox-manage housekeeping` still runs it on demand.

### Plugins

Pin them in `/opt/netbox/local_requirements.txt`, list them in the `plugins` array of `/etc/netbox/appliance.json`, then `netbox-upgrade --reinstall`.

### Metrics

Off unless `netbox.metrics-allow` was set at deploy time. When it is, `METRICS_ENABLED` is turned on, `prometheus-node-exporter` is enabled on loopback only, and nginx serves `/metrics` (NetBox) and `/node-metrics` (host) to the listed addresses and denies everyone else. Note NetBox's own caveat that Prometheus metrics from a multi-worker gunicorn are approximate.

### TLS

Self-signed by default, regenerated by `netbox-reconcile` when the appliance's addresses change. Supply `netbox.tls-cert`/`netbox.tls-key` at deploy time for a real certificate. **HSTS is only sent when an operator-supplied certificate is installed** — with a self-signed certificate it would turn the browser's warning into a page you cannot click through, locking you out of a freshly deployed appliance.

Those two form fields are read **once**, by the first-boot bootstrap, and there is no second first boot. A certificate that arrives later — the real one replacing the generated pair, a wildcard for the domain, a renewal — is installed with `netbox-tls`:

```
sudo netbox-tls show
sudo netbox-tls install fullchain.pem privkey.pem
```

It refuses a pair that does not match, a certificate that has already expired, and a file whose **first** certificate is not the leaf (nginx serves the file as given, so a chain in the wrong order works only in browsers that happen to have the intermediate cached). It warns, but proceeds, when no `subjectAltName` covers the name the appliance serves — wildcards included, so `*.example.com` counts as covering `netbox.example.com`. Then it removes `/etc/netbox/tls/.self-signed`, reloads, and checks the appliance still answers 200.

That marker is the part worth knowing about if you ever copy the files in by hand: it is how `netbox-reconcile` knows the certificate is the appliance's own, and while it is there **the next boot will reissue a self-signed certificate over yours**. Removing it is also what switches HSTS on, and what makes `netbox-status` stop reporting the certificate as self-signed. If nginx rejects the new pair, `netbox-tls` puts the old certificate, key and marker back before failing.

### Interaction with the hardened baseline

Everything the hardened base does is left in place. Two things it does are relevant here:

- `ufw` defaults to deny-incoming, so the build opens 80/tcp and 443/tcp. PostgreSQL, Redis and the node exporter stay bound to loopback and get no rule.
- fail2ban is configured with `banaction = ufw`; its default iptables actions would install rules alongside ufw's own chains. Two jails are enabled: `sshd` (journal backend, since Ubuntu 24.04 has no `auth.log` by default) and `netbox-login`, which reads nginx's access log because NetBox does not log rejected credentials itself — a `POST /login/` answering 200 re-rendered the form with an error, while a successful login answers 302.

`netbox.service` and `netbox-rq.service` additionally get `NoNewPrivileges`, `ProtectSystem=full`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID`, `RestrictRealtime` and `LockPersonality`. `ProtectSystem=strict`, `ProtectHome` and `MemoryDenyWriteExecute` are deliberately **not** set: NetBox runs operator-supplied custom scripts and reports, and those settings break them (and CPython extensions) in ways that only surface in production. The build asserts the drop-ins are actually in effect.

One thing to be aware of: `unattended-upgrades` keeps PostgreSQL, Redis and nginx patched, but it does **not** cover the Python packages inside `/opt/netbox/venv`. `netbox-upgrade` is the mechanism for those.
