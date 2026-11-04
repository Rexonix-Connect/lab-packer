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
# 24.04 server template. Its baseline is inherited, never reimplemented.
variable "sourceTemplateName" {
  type = string
}

# Vaultwarden release to ship. The image is pinned by digest as well as by
# tag: a tag can be moved, a digest cannot, and the build refuses an image
# whose digest does not match. Move both together - see vaultwarden-upgrade
# for the deployed-appliance equivalent.
variable "vaultwardenVersion" {
  type    = string
  default = "1.37.5"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.vaultwardenVersion))
    error_message = "The vaultwardenVersion variable must be a pinned release such as 1.37.5, never latest."
  }
}

# Digest of the multi-architecture image index for vaultwardenVersion, as
# shown by `docker buildx imagetools inspect vaultwarden/server:<version>` or
# the Docker Hub tag page.
variable "vaultwardenImageDigest" {
  type    = string
  default = "sha256:4fe17f415f90087377d37c755e0ea3cf189dcc6794e49cdd2a9adbb4937d9e1f"

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.vaultwardenImageDigest))
    error_message = "The vaultwardenImageDigest variable must be a sha256:<64 hex> image digest."
  }
}

variable "vaultwardenImageRepository" {
  type    = string
  default = "docker.io/vaultwarden/server"
}

# The Bitwarden Directory Connector CLI shipped in the image for Entra ID
# member sync (vaultwarden-dirsync). Pinned by release and by the sha256 of
# the bwdc-linux-<version>.zip release asset, which the GitHub release API
# reports as the asset's digest. Move both together.
variable "directoryConnectorVersion" {
  type    = string
  default = "2026.10.0"

  validation {
    condition     = can(regex("^[0-9]{4}\\.[0-9]+\\.[0-9]+$", var.directoryConnectorVersion))
    error_message = "The directoryConnectorVersion variable must be a pinned release such as 2026.10.0, never latest."
  }
}

variable "directoryConnectorSha256" {
  type    = string
  default = "b46e723804ab1ab3a8b3cb34cd5901acb44a570d94cdc5176e80ebde086dd994"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.directoryConnectorSha256))
    error_message = "The directoryConnectorSha256 variable must be the 64-hex sha256 of bwdc-linux-<version>.zip."
  }
}

# Throwaway account the build logs in with; finalize.sh deletes it.
variable "buildUsername" {
  type    = string
  default = "pkrbuild"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.buildUsername)) && !contains(["root", "vagrant", "recovery", "ubuntu", "vaultwarden", "postgres", "www-data"], var.buildUsername)
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

# Vaultwarden is light; PostgreSQL and the page cache are what use the memory.
# Comfortable for a few hundred users. Both can be changed at deploy time too.
variable "cpuCount" {
  type    = number
  default = 2
}

variable "memoryMb" {
  type    = number
  default = 8192
}

# Separate thin disk mounted at /srv/vaultwarden, holding the PostgreSQL
# cluster, the Vaultwarden data directory (attachments, Sends, the RSA signing
# key) and the local backups. Attached through the vCenter API, like the NetBox
# appliance's, because the plugin rejects a storage block for an OVF source.
variable "dataDiskGb" {
  type    = number
  default = 100

  validation {
    condition     = var.dataDiskGb >= 20
    error_message = "The dataDiskGb variable must be at least 20 GB."
  }
}

# Re-asserted on the clone so the appliance keeps the base's Secure Boot
# setting. It must match the firmware the hardened template was built with.
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
