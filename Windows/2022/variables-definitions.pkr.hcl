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
  default = 90
}

variable "isoPath" {
  type = string
}

# Datastore path to the VMware Tools ISO. Defaults to the ESXi host's bundled
# copy, whose version tracks the host patch level; override with a pinned,
# reviewable ISO uploaded to a datastore (see README) to control the Tools
# version independently of the host.
variable "toolsIsoPath" {
  type    = string
  default = "[] /vmimages/tools-isoimages/windows.iso"
}

# Minimum acceptable installed VMware Tools version; the build fails if the
# tools ISO yields anything older. Empty disables the check.
variable "minimumToolsVersion" {
  type    = string
  default = "12.5.4"
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

variable "vmUsername" {
  type    = string
  default = "vagrant"
}

variable "vmPassword" {
  type      = string
  sensitive = true
}

# Initial WinRM connect covers the unattended OS install, first-logon VMware
# Tools installation and reboot handling before Packer can reach the guest.
variable "winrmTimeout" {
  type    = string
  default = "2h"
}

variable "cpuCount" {
  type    = number
  default = 4
}

variable "memoryMb" {
  type    = number
  default = 8192
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

# WIM image index on standard Microsoft Windows Server ISOs:
# 1 = Standard Core, 2 = Standard (Desktop Experience),
# 3 = Datacenter Core, 4 = Datacenter (Desktop Experience).
variable "windowsImageIndex" {
  type    = number
  default = 2
}

# Empty installs without a key (evaluation ISOs); set a KMS client setup key
# or a volume license key for licensed media.
variable "windowsProductKey" {
  type      = string
  default   = ""
  sensitive = true
}

# Pinned Cloudbase-Init release installed into the template for deploy-time
# personalization (vApp form via OVF ISO, NoCloud/ConfigDrive, guestinfo).
variable "cloudbaseInitVersion" {
  type    = string
  default = "1.1.8"
}

variable "windowsLanguage" {
  type    = string
  default = "en-US"
}

variable "windowsTimezone" {
  type    = string
  default = "UTC"
}
