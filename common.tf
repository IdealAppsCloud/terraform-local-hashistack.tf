#
# Variables
##

variable "bindir" {
  default = "/usr/local/bin"
}

variable "installdir" {
  default = "/var/lib/hashistack"
}

#
# Constants
#

locals {
  consul_version = "1.6.3"
  vault_version  = "1.3.2"
  nomad_version  = "0.10.3"

  bindir = var.bindir
}

#
# Resources
#

resource "sys_dir" "installdir" {
  path = var.installdir
  allow_existing = true
}

resource "sys_dir" "etc-firewall" {
  path = "/etc/firewall"
  allow_existing = true
}
