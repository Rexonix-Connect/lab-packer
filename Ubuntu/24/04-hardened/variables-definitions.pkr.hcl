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

variable "diskSizeGb" {
  type    = number
  default = 60

  validation {
    condition     = var.diskSizeGb >= 25
    error_message = "Disk size must be at least 25 GB."
  }
}

variable "vmUsername" {
  type      = string
  sensitive = true
}

variable "vmPassword" {
  type      = string
  sensitive = true
}

variable "vmPasswordHash" {
  type      = string
  sensitive = true
}

# Console break-glass account password hash (crypt SHA-512); the password
# only works on the hypervisor console because SSH password authentication
# is disabled during finalize.
variable "recoveryPasswordHash" {
  type      = string
  sensitive = true
}

variable "sshTimeout" {
  type    = string
  default = "45m"
}

# Installs the full Ubuntu desktop task on top of the server base, producing a
# desktop VM template from the same server ISO with one build mechanism for
# both flavors.
variable "installDesktop" {
  type    = bool
  default = false
}

variable "cpuCount" {
  type    = number
  default = 2
}

variable "memoryMb" {
  type    = number
  default = 4096
}

# Virtual hardware version of the built VM, and so of the OVF exported to the
# content library.
#
# Left unset, the builder creates the VM at the build cluster's maximum -
# vmx-21 on ESXi 8.0 U2 - and a vCenter that does not know that version refuses
# to deploy from the item at all: "No supported hardware versions among
# [vmx-21]; supported: [vmx-04 ... vmx-19]". A template built in a lab running
# newer ESXi than the environment it is deployed into is unusable there, and
# nothing says so until somebody tries, in a different vCenter, possibly a
# customer's.
#
# 19 is ESXi 7.0 U2 and later. Nothing in these images needs anything newer:
# UEFI Secure Boot arrived at vmx-13, pvscsi and vmxnet3 long before that, and
# the vCPU and memory ceilings at 19 are far above anything built here. Lower
# it for older targets, raise it only for a feature that requires it and only
# once every target vCenter is new enough. Hardware version can be raised on an
# existing VM but never lowered, so a template built too new has to be rebuilt.
variable "vmHardwareVersion" {
  type    = number
  default = 19

  validation {
    condition     = var.vmHardwareVersion >= 13
    error_message = "Hardware version must be at least 13 (ESXi 6.5, the first to support UEFI Secure Boot)."
  }
}

variable "minimumKmodVersion" {
  type    = string
  default = "31+20240202-2ubuntu7.2"
}

# Oldest kernel that fixes the 2026 LPE family: CVE-2026-31431 "Copy Fail",
# CVE-2026-46331 "pedit COW", CVE-2026-46300 "Fragnesia", CVE-2026-43284 and
# CVE-2026-43500 "Dirty Frag", CVE-2026-43503 "DirtyClone", CVE-2026-46333
# "ssh-keysign-pwn".
variable "minimumKernelVersion" {
  type    = string
  default = "6.8.0-124.124"
}

# VM firmware. The hardened image defaults to UEFI Secure Boot (parity with
# the Windows templates), which turns on kernel lockdown in integrity mode.
# Fall back to "efi" or "bios" if a particular vSphere environment cannot boot
# the signed installer under Secure Boot.
variable "firmware" {
  type    = string
  default = "efi-secure"
  validation {
    condition     = contains(["efi-secure", "efi", "bios"], var.firmware)
    error_message = "The firmware variable must be one of efi-secure, efi, or bios."
  }
}

variable "isoPath" {
  type = string
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
