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

variable "sshTimeout" {
  type    = string
  default = "45m"
}

variable "minimumKmodVersion" {
  type    = string
  default = "29-1ubuntu1.1"
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
