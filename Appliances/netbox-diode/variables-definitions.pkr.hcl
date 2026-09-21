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
# 24.04 server template, exactly as the NetBox appliance clones it. The two
# images are siblings and must not drift apart - everything the hardened base
# guarantees is inherited here rather than reimplemented.
variable "sourceTemplateName" {
  type = string
}

# Diode server release to run. There is deliberately no default: the upstream
# compose file defaults its own tag to "latest", which is the one thing an
# appliance must never ship, and inventing a plausible-looking pin here would
# be worse than making the build ask for one. Set it to the Diode release the
# vendored compose file was checked against.
variable "diodeVersion" {
  type = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.diodeVersion))
    error_message = "The diodeVersion variable must be a pinned release tag such as v1.2.3."
  }
}

# NetBox Discovery agent (orb-agent) release. Pinned for the same reason, and
# separately from the server: the two projects release independently.
variable "agentVersion" {
  type = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.agentVersion))
    error_message = "The agentVersion variable must be a pinned release tag such as v1.2.3."
  }
}

# Throwaway account the build logs in with. The hardened base removes its own
# provisioning account and disables SSH password authentication, so the build
# seeds this one through cloud-init and finalize.sh deletes it again.
variable "buildUsername" {
  type    = string
  default = "pkrbuild"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.buildUsername)) && !contains(["root", "vagrant", "recovery", "ubuntu", "diode", "netbox", "postgres", "www-data"], var.buildUsername)
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

# Nine containers, but light ones: the heavy user here is PostgreSQL plus the
# optional discovery agent, whose own documentation asks for 2 cores and
# 1.5 GB before anything else on the box. 4/8192 leaves room for both without
# the 16 GB the NetBox appliance needs for gunicorn and its database.
variable "cpuCount" {
  type    = number
  default = 4
}

variable "memoryMb" {
  type    = number
  default = 8192
}

# Separate thin disk mounted at /srv/diode, holding the Docker data root -
# which is both the baked container images and every named volume, so the
# Diode PostgreSQL cluster and the Redis append-only file land here - plus the
# backups. The 60 GB root inherited from the hardened base is then never in
# the path of anything that grows.
#
# It cannot be declared in the source block: packer-plugin-vsphere rejects a
# storage block outright for an OVF-backed content library source ("'storage'
# cannot be used with OVF content library items"), so the build attaches it
# through the vCenter API instead - see shared/scripts/add-vm-disk.py.
variable "dataDiskGb" {
  type    = number
  default = 100

  validation {
    condition     = var.dataDiskGb >= 40
    error_message = "The dataDiskGb variable must be at least 40 GB; the baked container images alone are several GB before any data."
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
