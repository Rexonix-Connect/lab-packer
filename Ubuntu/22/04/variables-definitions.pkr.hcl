variable "vCenterServer" {
  type = string
}

variable "vCenterUsername" {
  type = string
  sensitive = true
}

variable "vCenterPassword" {
  type = string
  sensitive = true
}

variable "vCenterDatacenterName" {
  type = string
}

variable "vCenterInsecureConnection" {
  type = string
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

variable "vmUsername" {
  type = string
  sensitive = true
}

variable "vmPassword" {
  type = string
  sensitive = true
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
