packer {
  required_version = "= 1.10.1"
  required_plugins {
    # 2.2.0+ is required for vApp property support in the vsphere-iso builder.
    vsphere = {
      version = "= 2.3.0"
      source  = "github.com/hashicorp/vsphere"
    }
    ansible = {
      version = "= 1.1.3"
      source  = "github.com/hashicorp/ansible"
    }
    windows-update = {
      version = "= 0.18.4"
      source  = "github.com/rgl/windows-update"
    }
  }
}
