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

variable "minimumKmodVersion" {
  type    = string
  default = "29-1ubuntu1.1"
}

# Oldest kernel that fixes the 2026 LPE family: CVE-2026-31431 "Copy Fail",
# CVE-2026-46331 "pedit COW", CVE-2026-46300 "Fragnesia", CVE-2026-43284 and
# CVE-2026-43500 "Dirty Frag", CVE-2026-43503 "DirtyClone", CVE-2026-46333
# "ssh-keysign-pwn".
variable "minimumKernelVersion" {
  type    = string
  default = "5.15.0-181.191"
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
