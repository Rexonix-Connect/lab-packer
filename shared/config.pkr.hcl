packer {
  required_version = ">1.7.0"
  required_plugins {
    vsphere = {
      version = "= 2.1.2"
      source = "github.com/hashicorp/vsphere"
    }
    ansible = {
      version = "= 1.1.3"
      source  = "github.com/hashicorp/ansible"
    }
  }
}
