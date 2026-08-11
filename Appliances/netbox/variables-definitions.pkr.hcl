variable "vCenterServer" {
  type = string
}

variable "vCenterUsername" {
  type      = string
  sensitive = true
}

variable "vCenterPassword" {
  type      = string
  sensitive = true
}

variable "vCenterDatacenterName" {
  type = string
}

variable "vCenterInsecureConnection" {
  type    = bool
  default = false
}

variable "vmName" {
  type = string
}

variable "vmFolder" {
  type = string
}

variable "clusterName" {
  type = string
}

variable "datastoreName" {
  type = string
}

# Content library item this appliance is cloned from: the hardened Ubuntu
# 24.04 server template. Everything the hardened image guarantees (Secure Boot
# and kernel lockdown, the CVE module blocks, the sysctl baseline, auditd, the
# SSH crypto policy, the recovery break-glass account) is inherited rather than
# reimplemented, so the two images cannot drift apart.
variable "sourceTemplateName" {
  type = string
}

# NetBox release tag to install. Pinned like every other version in this repo;
# override it per build to move the appliance forward.
variable "netboxVersion" {
  type    = string
  default = "v4.6.7"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.netboxVersion))
    error_message = "The netboxVersion variable must be a pinned release tag such as v4.6.7."
  }
}

variable "netboxRepoUrl" {
  type    = string
  default = "https://github.com/netbox-community/netbox.git"
}

# Throwaway account the build logs in with. The hardened base removes its own
# provisioning account and disables SSH password authentication, so the build
# seeds this one through cloud-init and finalize.sh deletes it again.
variable "buildUsername" {
  type    = string
  default = "pkrbuild"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.buildUsername)) && !contains(["root", "vagrant", "recovery", "ubuntu", "netbox", "postgres", "www-data"], var.buildUsername)
    error_message = "The buildUsername variable must be a valid Linux account name that no account in the image already uses."
  }
}

# Ephemeral SSH key pair generated per build run by the workflow; the public
# half is authorized in the guest, the private half never leaves the runner.
variable "buildPublicKey" {
  type = string
}

variable "buildPrivateKeyFile" {
  type      = string
  sensitive = true
}

variable "sshTimeout" {
  type    = string
  default = "45m"
}

variable "ipWaitTimeout" {
  type    = string
  default = "20m"
}

# NetBox plus PostgreSQL, Redis, gunicorn and nginx on one guest: 2 vCPU and
# 4 GB (the OS templates' defaults) is below what a working instance needs.
variable "cpuCount" {
  type    = number
  default = 4
}

variable "memoryMb" {
  type    = number
  default = 16384
}

# Separate thin disk mounted at /srv/netbox, holding the NetBox installation,
# the PostgreSQL cluster and the backups, so the 60 GB root inherited from the
# hardened base cannot be filled by NetBox's own growth.
#
# It cannot be declared in the source block: packer-plugin-vsphere rejects a
# storage block outright for an OVF-backed content library source ("'storage'
# cannot be used with OVF content library items"), so the build attaches it
# through the vCenter API instead - see shared/scripts/add-vm-disk.py.
variable "dataDiskGb" {
  type    = number
  default = 150

  validation {
    condition     = var.dataDiskGb >= 50
    error_message = "The dataDiskGb variable must be at least 50 GB; below that the separate data disk is not worth the split."
  }
}

# Re-asserted on the clone so the appliance keeps the base's Secure Boot
# setting even if the OVF export loses it. It must match the firmware the
# hardened template was built with, or the clone will not boot.
variable "firmware" {
  type    = string
  default = "efi-secure"

  validation {
    condition     = contains(["efi-secure", "efi", "bios"], var.firmware)
    error_message = "The firmware variable must be one of efi-secure, efi, or bios."
  }
}

variable "templateName" {
  type = string
}

variable "libraryName" {
  type = string
}

variable "portGroup" {
  type = string
}
