#
# Variables
#

variable "nomad_region" {
  default = "global"
}

variable "nomad_dc" {
  default = "dc-1"
}

variable "nomad_bootstrap_expect" {
  description = "bootstrap-expect value to pass to Consul"
  default = 1
}

variable "nomad_server" {
  description = "1 to enable server, 0 to disable"
  default = 1
}

variable "nomad_client" {
  description = "1 to enable client, 0 to disable"
  default = 1
}

variable "nomad_override_cpu_total_compute" {
  default = 15000
}

variable "nomad_override_memory_total_mb" {
  default = 15000
}

variable "nomad_override_network_speed" {
  default = 1000
}

variable "nomad_enable_raw_exec" {
  default = 1
}

variable "nomad_override_kill_timeout" {
  default = "1m"
}

#
# Resources
#

resource "sys_file" "nomad_archive" {
  source   = "https://releases.hashicorp.com/nomad/${local.nomad_version}/nomad_${local.nomad_version}_linux_amd64.zip"
  filename = "${sys_dir.installdir.path}/nomad-${local.nomad_version}"

  provisioner "local-exec" {
    command = <<SCRIPT
      setcap cap_ipc_lock=+ep "${sys_dir.installdir.path}/nomad-${local.nomad_version}"
    SCRIPT
  }
}

resource "sys_symlink" "nomad" {
  source = sys_file.nomad_archive.filename
  path = "${local.bindir}/nomad"
}

resource "sys_file" "nomad_firewall" {
  filename = "${sys_dir.etc-firewall.path}/nomad.nft"
  content = <<EOF
#!/sbin/nft -f
add table inet nomad
flush table inet nomad
table inet nomad {
  chain nomad-input {
    type filter hook input priority 0
    meta iifname docker0 accept comment "Accept docker traffic"
    meta iifname lo accept comment "Accept loopback traffic"
    tcp dport {4646, 4647, 4648} reject comment "Reject Nomad unless authorized before"
    udp dport {4646, 4647, 4648} reject comment "Reject Nomad unless authorized before"
  }
}
EOF
}

resource "sys_file" "nomad_config" {
  filename = "/etc/nomad.hcl"
  content = <<EOF
bind_addr = "0.0.0.0"
#bind_addr = "127.0.0.1"
#bind_addr = "{{ GetPrivateIPs }}"

advertise {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

client {
  enabled = ${var.nomad_client == 1 ? "true" : "false"}
  max_kill_timeout = "${var.nomad_override_kill_timeout}"
  cpu_total_compute = ${var.nomad_override_cpu_total_compute}
  memory_total_mb = ${var.nomad_override_memory_total_mb}
  network_speed = ${var.nomad_override_network_speed}
  options = {
    "driver.raw_exec.enable" = "${var.nomad_enable_raw_exec}"
  }
}

EOF
}

resource "null_resource" "nomad_consul_policy" {
  triggers = {
    consul_up = sys_null.consul_systemd.outputs.up
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      consul acl policy create -name=nomad -rules=- <<'      POLICY'
        # Authorize everything until we find a better policy
        acl = "write"
        agent_prefix "" {
          policy = "write"
        }
        event_prefix "" {
          policy = "write"
        }
        key_prefix "" {
          policy = "write"
        }
        keyring="write"
        node_prefix "" {
          policy = "write"
        }
        operator="write"
        query_prefix "" {
          policy = "write"
        }
        service_prefix "" {
          policy = "write"
        }
        session_prefix "" {
          policy = "write"
        }
      POLICY
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      consul acl policy delete -name=nomad
    SCRIPT
  }
}

resource "null_resource" "nomad_consul_token" {
  triggers = {
    consul_up = sha1(jsonencode(null_resource.nomad_consul_policy.triggers))
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      umask 0077
      consul acl token create -policy-name=nomad -description=nomad \
        | sed -r -n 's/SecretID: *(.*)/consul { token = "\1" }/p' \
        | tee /etc/nomad-token.hcl
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      rm -f /etc/nomad-token.hcl
    SCRIPT
  }
}

resource "sys_file" "nomad_service_firewall" {
  filename = "/etc/systemd/system/nomad-firewall.service"
  content = <<EOF
[Unit]
Description="Firewall for Nomad"
Requires=network-online.target
After=network-online.target

[Service]
ExecStart=/sbin/nft -f ${sys_dir.etc-firewall.path}/nomad.nft
RemainAfterExit=true
EOF
}

resource "sys_file" "nomad_service" {
  filename = "/etc/systemd/system/nomad.service"
  content = <<EOF
[Unit]
Description=Nomad server and agent
After=network.target
Before=multi-user.target
Wants=consul.service
After=consul.service
Requires=nomad-firewall.service
After=nomad-firewall.service

[Service]
Type=simple
ExecStart=${local.bindir}/nomad agent \
  -config=/etc/nomad.hcl \
  -config=/etc/nomad-token.hcl \
  -data-dir=/var/lib/nomad \
  -region=${var.nomad_region} \
  -dc=${var.nomad_dc} \
  ${var.nomad_server == 1 ? "-server" : ""} \
  ${var.nomad_client == 1 ? "-client" : ""} \
  -bootstrap-expect=${var.nomad_bootstrap_expect}
ExecReload=/bin/kill -HUP $MAINPID
Restart=always

[Install]
WantedBy=multi-user.target
EOF
}

resource "sys_null" "nomad_systemd" {
  triggers = {
    nomad                  = sys_symlink.nomad.id
    nomad_firewall         = sys_file.nomad_firewall.id
    nomad_config           = sys_file.nomad_config.id
    nomad_consul_policy    = null_resource.nomad_consul_policy.id
    nomad_consul_token     = null_resource.nomad_consul_token.id
    nomad_service_firewall = sys_file.nomad_service_firewall.id
    nomad_service          = sys_file.nomad_service.id
  }

  inputs = {
    up = 1
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl enable --now io.podman.socket
      systemctl enable --now nomad.service
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl disable --now nomad.service
    SCRIPT
  }
}

#
# Outputs
#

output "nomad_up" {
  value = sys_null.nomad_systemd.outputs.up
}
