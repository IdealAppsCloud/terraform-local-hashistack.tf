#
# Resources
#

resource "sys_file" "vault_archive" {
  source   = "https://releases.hashicorp.com/vault/${local.vault_version}/vault_${local.vault_version}_linux_amd64.zip"
  filename = "${sys_dir.installdir.path}/vault-${local.vault_version}"

  provisioner "local-exec" {
    command = <<SCRIPT
      setcap cap_ipc_lock=+ep "${sys_dir.installdir.path}/vault-${local.vault_version}"
    SCRIPT
  }
}

resource "sys_symlink" "vault" {
  source = sys_file.vault_archive.filename
  path = "${local.bindir}/vault"
}

resource "sys_file" "vault_sysuser" {
  filename = "/etc/sysusers.d/vault.conf"
  content = <<EOF
u vault - "Vault" /etc/vault.d
EOF

  provisioner "local-exec" {
    command = <<SCRIPT
      systemd-sysusers
    SCRIPT
  }
}

resource "sys_file" "vault_firewall" {
  filename = "${sys_dir.etc-firewall.path}/vault.nft"
  content = <<EOF
#!/sbin/nft -f
add table inet vault
flush table inet vault
table inet vault {
  chain vault-input {
    type filter hook input priority 0
    meta iifname docker0 accept comment "Accept docker traffic"
    meta iifname lo accept comment "Accept loopback traffic"
    tcp dport {8200, 8201} reject comment "Reject Vault unless authorized before"
  }
}
EOF
}

resource "sys_file" "vault_config" {
  depends_on = [ sys_file.vault_sysuser ]
  filename = "/etc/vault.d/vault.hcl"
  file_permission = "0640"

  provisioner "local-exec" {
    command = <<SCRIPT
      chown vault:vault /etc/vault.d/vault.hcl
    SCRIPT
  }

  content = <<EOF
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
EOF
}

resource "null_resource" "vault_consul_policy" {
  triggers = {
    consul_up = sys_null.consul_systemd.outputs.up
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      consul acl policy create -name=vault -rules=- <<'      POLICY'
        node "" {
          policy = "write"
        }
        service "vault" {
          policy = "write"
        }
        agent "" {
          policy = "write"
        }
        key "vault" {
          policy = "write"
        }
        session "" {
          policy = "write"
        }
      POLICY
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      consul acl policy delete -name=vault
    SCRIPT
  }
}

resource "null_resource" "vault_consul_token" {
  depends_on = [ sys_file.vault_sysuser ]
  triggers = {
    consul_up = null_resource.vault_consul_policy.id
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      export CONSUL_HTTP_TOKEN='${local.consul_master_token}'
      umask 0077
      consul acl token create -policy-name=vault -description=vault \
        | sed -r -n 's/SecretID: *(.*)/storage "consul" { token = "\1" }/p' \
        | tee /etc/vault.d/consul-token.hcl
      chown vault:vault /etc/vault.d/consul-token.hcl
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      rm -f /etc/vault.d/consul-token.hcl
    SCRIPT
  }
}

resource "sys_file" "vault_service_firewall" {
  filename = "/etc/systemd/system/vault-firewall.service"
  content = <<EOF
[Unit]
Description="Firewall for Vault"
Requires=network-online.target
After=network-online.target

[Service]
ExecStart=/sbin/nft -f ${sys_dir.etc-firewall.path}/vault.nft
RemainAfterExit=true
EOF
}

resource "sys_file" "vault_service" {
  filename = "/etc/systemd/system/vault.service"
  content = <<EOF
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
Requires=vault-firewall.service
After=vault-firewall.service
Wants=consul.service
After=consul.service
ConditionFileNotEmpty=/etc/vault.d/vault.hcl
StartLimitBurst=3
StartLimitInterval=60s

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_SYSLOG CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStartPre=+-/bin/touch /etc/vault.d/consul-token.hcl
ExecStart=${local.bindir}/vault server \
    -config=/etc/vault.d/vault.hcl \
    -config=/etc/vault.d/consul-token.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

resource "sys_null" "vault_systemd" {
  triggers = {
    vault                  = sys_symlink.vault.id
    vault_firewall         = sys_file.vault_sysuser.id
    vault_firewall         = sys_file.vault_firewall.id
    vault_config           = sys_file.vault_config.id
    vault_consul_policy    = null_resource.vault_consul_policy.id
    vault_consul_token     = null_resource.vault_consul_token.id
    vault_service_firewall = sys_file.vault_service_firewall.id
    vault_service          = sys_file.vault_service.id
  }

  inputs = {
    up = 1
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl enable --now vault.service
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl disable --now vault.service
    SCRIPT
  }
}

#
# Outputs
#

output "vault_up" {
  value = sys_null.vault_systemd.outputs.up
}
