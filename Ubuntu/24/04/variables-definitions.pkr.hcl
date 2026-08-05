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
