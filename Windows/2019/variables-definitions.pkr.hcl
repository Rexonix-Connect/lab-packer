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

variable "windowsLanguage" {
  type    = string
  default = "en-US"
}

variable "windowsTimezone" {
  type    = string
  default = "UTC"
}
