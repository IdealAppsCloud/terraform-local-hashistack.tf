#
# Variables
#

variable "consul_bootstrap_expect" {
  description = "bootstrap-expect value to pass to Consul"
  default = 1
}

variable "consul_key" {
  description = "Consul cluster key, if not provided, a key will be generated"
  default = ""
}

variable "consul_master_token" {
  description = "Consul master token to provision, if not provided, a token will be generated"
  default = ""
}

#
# Resources
#

resource "sys_file" "consul_archive" {
  source   = "https://releases.hashicorp.com/consul/${local.consul_version}/consul_${local.consul_version}_linux_amd64.zip"
  #filename = "${sys_dir.installdir.path}/consul-${local.consul_version}.zip"
  filename = "${sys_dir.installdir.path}/consul-${local.consul_version}"
}

/*
resource "sys_shell_script" "consul_unzip" {
  working_directory = sys_dir.installdir.path

  create = <<SCRIPT
    unzip ${sys_file.consul_archive.filename} -d $PWD -x consul
    chmod +x consul
    mv -i consul consul-${local.consul_version} </dev/null
  SCRIPT

  delete = <<SCRIPT
    rm -f consul-${local.consul_version}
  SCRIPT

  read = <<SCRIPT
    cat consul-${local.consul_version} 2>/dev/null
    true
  SCRIPT
}
*/

resource "sys_symlink" "consul" {
  #source = "${sys_dir.installdir.path}/consul-${local.consul_version}"
  source = sys_file.consul_archive.filename
  path = "${local.bindir}/consul"
}

resource "sys_file" "consul_firewall" {
  filename = "${sys_dir.etc-firewall.path}/consul.nft"
  content = <<EOF
#!/sbin/nft -f
add table inet consul
flush table inet consul
table inet consul {
  chain consul-input {
    type filter hook input priority 0
    meta iifname docker0 accept comment "Accept docker traffic"
    meta iifname lo accept comment "Accept loopback traffic"
    tcp dport {8300, 8301, 8302, 8500, 8600} reject comment "Reject Consul unless authorized above"
    udp dport {8300, 8301, 8302, 8500, 8600} reject comment "Reject Consul unless authorized above"
  }
}
EOF
}

resource "sys_file" "consul_config" {
  filename = "/etc/consul.json"
  content = <<EOF
{
  "data_dir": "/var/lib/consul",
  "leave_on_terminate": true,
  "ui": true,
  "primary_datacenter": "dc1",
  "acl": {
    "enabled": true,
    "down_policy": "extend-cache",
    "default_policy": "allow"
  }
}
EOF
}

resource "random_id" "consul_key" {
  byte_length = 16
}

resource "random_uuid" "consul_master_token" {
}

locals {
  consul_key          = var.consul_key          != "" ? var.consul_key          : random_id.consul_key.b64_std
  consul_master_token = var.consul_master_token != "" ? var.consul_master_token : random_uuid.consul_master_token.result
}

resource "sys_file" "consul_token" {
  filename = "/etc/consul-token.json"
  file_permission = "0600"
  content = <<EOF
{
  "encrypt": "${local.consul_key}",
  "acl": {
    "tokens": {
      "master": "${local.consul_master_token}"
    }
  }
}
EOF
}

resource "sys_file" "consul_service_firewall" {
  filename = "/etc/systemd/system/consul-firewall.service"
  content = <<EOF
[Unit]
Description="Firewall for Consul"
Requires=network-online.target
After=network-online.target

[Service]
ExecStart=/sbin/nft -f ${sys_dir.etc-firewall.path}/consul.nft
RemainAfterExit=true
EOF
}

resource "sys_file" "consul_service" {
  filename = "/etc/systemd/system/consul.service"
  content = <<EOF
[Unit]
Description=Consul Server Node
After=network.target
Before=multi-user.target
Requires=consul-firewall.service
After=consul-firewall.service

[Service]
Type=simple
Environment=CONSUL_VERSION=1.2.0
ExecStartPre=/sbin/nft -f ${sys_dir.etc-firewall.path}/consul.nft
ExecStart=${local.bindir}/consul agent \
  -config-file=/etc/consul.json \
  -config-file=/etc/consul-token.json \
  -server \
  -bind=127.0.0.1 \
  -client=0.0.0.0 \
  -bootstrap-expect=${var.consul_bootstrap_expect}
ExecStop=${local.bindir}/consul leave
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

resource "sys_null" "consul_systemd" {
  triggers = {
    consul_config           = sys_file.consul_config.id
    consul_firewall         = sys_file.consul_firewall.id
    consul_service          = sys_file.consul_service.id
    consul_service_firewall = sys_file.consul_service_firewall.id
    consul                  = sys_symlink.consul.id
    consul_token            = sys_file.consul_token.id
  }

  inputs = {
    up = 1
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl enable --now consul.service
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl disable --now consul.service
    SCRIPT
  }
}

#
# Outputs
#

output "consul_up" {
  value = sys_null.consul_systemd.outputs.up
}

