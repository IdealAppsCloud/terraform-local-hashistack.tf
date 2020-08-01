resource "sys_file" "dns_dnsmasq_firewall" {
  filename = "${sys_dir.etc-firewall.path}/dnsmasq.nft"
  content = <<EOF
#!/sbin/nft -f
add table inet dnsmasq
flush table inet dnsmasq
table inet dnsmasq {
  chain dnsmasq-input {
    type filter hook input priority 0
    meta iifname docker0 accept comment "Accept docker traffic"
    meta iifname lo accept comment "Accept loopback traffic"
    tcp dport 53 reject comment "Deny DNS unless accepted above"
    udp dport 53 reject comment "Deny DNS unless accepted above"
  }
}
EOF
}

resource "sys_file" "dns_dnsmasq_service_firewall" {
  filename = "/etc/systemd/system/dnsmasq-firewall.service"
  content = <<EOF
[Unit]
Description="Firewall for Dnsmasq"
Requires=network-online.target
After=network-online.target

[Service]
ExecStart=/sbin/nft -f ${sys_file.dns_dnsmasq_firewall.filename}
RemainAfterExit=true
EOF
}

resource "sys_file" "dns_nsdns_service" {
  filename = "/etc/systemd/system/nsdns.service"
  content = <<EOF
[Unit]
Description=DNS resolver that add consul suffix
Wants=network-online.target
After=network-online.target
Before=multi-user.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm nsdns
ExecStart=/usr/bin/podman run --rm \
  --name=nsdns \
  --net=host \
  -e NSDNS_LISTEN_ADDR=127.0.0.1:9653 \
  quay.io/mildred/nsdns
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

resource "sys_file" "dns_dnsmasq_service" {
  filename = "/etc/systemd/system/dnsmasq.service"
  content = <<EOF
[Unit]
Description=DNS resolver that add consul suffix
Wants=network-online.target
After=network-online.target
Before=multi-user.target
Requires=consul.service dnsmasq-firewall.service nsdns.service
After=consul.service dnsmasq-firewall.service nsdns.service

[Service]
Type=simple
TimeoutStartSec=0
ExecStart=/usr/sbin/dnsmasq \
    --keep-in-foreground \
    --except-interface=enp1s0 \
    --server='/consul/127.0.0.1#8600' \
    --server='/ns-consul/127.0.0.1#9653' \
    --log-facility=- \
    --cache-size=0 \
    --no-negcache \
    --dns-forward-max=500
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

resource "sys_null" "dns_dnsmasq_systemd" {
  triggers = {
    dnsmasq_firewall         = sys_file.dns_dnsmasq_firewall.id
    dnsmasq_service          = sys_file.dns_dnsmasq_service.id
    dnsmasq_service_firewall = sys_file.dns_dnsmasq_service_firewall.id
  }

  inputs = {
    up = 1
  }

  provisioner "local-exec" {
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl enable --now dnsmasq.service
    SCRIPT
  }

  provisioner "local-exec" {
    when = destroy
    command = <<SCRIPT
      systemctl daemon-reload
      systemctl disable --now dnsmasq.service
    SCRIPT
  }
}

#
# Outputs
#

output "dns_dnsmasq_up" {
  value = sys_null.dns_dnsmasq_systemd.outputs.up
}
