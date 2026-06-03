/*
 * role-overlay-citus-nftables-backplane.tf -- per-cluster nftables for the 9
 * citus-tier nodes (3 etcd + coordinator pair + 2 worker pairs). Phase 0.P.
 *
 * Ports opened on VMnet11 (service):
 *   - 22       sshd
 *   - 5432     PostgreSQL (client coordinator endpoint via the VIP; also the
 *              port every PG node listens on)
 *   - 8008     Patroni REST (every PG node listens; keepalived's vrrp_script +
 *              the smoke gate probe it)
 *   - 2379     etcd client API (only etcd nodes listen; Patroni dials this)
 *   - 2380     etcd peer raft (only etcd nodes listen; mesh between members)
 *   - 9100     node_exporter
 *   - proto 112 + 224.0.0.18 multicast: VRRP for keepalived within each PG
 *     node-group (unicast in practice -- VMware VMnet doesn't traverse
 *     multicast reliably -- but the rules are harmless on the etcd hosts and
 *     the multicast accept is defense-in-depth).
 *
 * VMnet10 whole-segment trust: streaming replication + coordinator<->worker
 * traffic + Patroni<->etcd + VRRP unicast all ride the backplane.
 */

locals {
  citus_node_ips = compact([
    var.enable_etcd_1 ? "192.168.70.202" : "",
    var.enable_etcd_2 ? "192.168.70.203" : "",
    var.enable_etcd_3 ? "192.168.70.204" : "",
    var.enable_coord_1 ? "192.168.70.205" : "",
    var.enable_coord_2 ? "192.168.70.206" : "",
    var.enable_worker1_1 ? "192.168.70.207" : "",
    var.enable_worker1_2 ? "192.168.70.208" : "",
    var.enable_worker2_1 ? "192.168.70.209" : "",
    var.enable_worker2_2 ? "192.168.70.210" : "",
  ])

  citus_nftables_ruleset = <<-NFT
    #!/usr/sbin/nft -f
    # Managed by nexus-infra-citus/terraform/envs/citus/role-overlay-citus-nftables-backplane.tf
    # DO NOT EDIT BY HAND -- terraform overlay re-applies on every apply.
    # ruleset_v=1 (per-cluster citus scope; Patroni HA + etcd DCS + VRRP)

    flush ruleset

    table inet filter {
      chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop

        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        # VMnet11 service network
        iifname "nic0" tcp dport 22 accept    # sshd
        iifname "nic0" tcp dport 5432 accept  # PostgreSQL (PG nodes; coordinator VIP client endpoint)
        iifname "nic0" tcp dport 8008 accept  # Patroni REST (PG nodes; keepalived check + smoke)
        iifname "nic0" tcp dport 2379 accept  # etcd client API (etcd nodes)
        iifname "nic0" tcp dport 2380 accept  # etcd peer raft (etcd nodes)
        iifname "nic0" tcp dport 9100 accept  # node_exporter

        # VRRP for keepalived within each PG node-group (unicast in practice on
        # this lab; multicast advertised here as belt+braces).
        iifname "nic0" ip protocol 112 accept                      # VRRP unicast
        iifname "nic0" ip daddr 224.0.0.18 ip protocol 112 accept  # VRRP multicast advertisements

        # VMnet10 cluster backplane: streaming replication + coordinator<->worker
        # + Patroni<->etcd + pg_basebackup + VRRP unicast.
        iifname "nic1" ip saddr 192.168.10.0/24 accept

        counter drop
      }

      chain forward {
        type filter hook forward priority filter; policy drop;
      }

      chain output {
        type filter hook output priority filter; policy accept;
      }
    }
  NFT
}

resource "null_resource" "citus_nftables_backplane" {
  count = var.enable_nftables_backplane ? 1 : 0

  triggers = {
    etcd_1      = length(module.etcd_1) > 0 ? module.etcd_1[0].vm_name : "absent"
    etcd_2      = length(module.etcd_2) > 0 ? module.etcd_2[0].vm_name : "absent"
    etcd_3      = length(module.etcd_3) > 0 ? module.etcd_3[0].vm_name : "absent"
    coord_1     = length(module.coord_1) > 0 ? module.coord_1[0].vm_name : "absent"
    coord_2     = length(module.coord_2) > 0 ? module.coord_2[0].vm_name : "absent"
    worker1_1   = length(module.worker1_1) > 0 ? module.worker1_1[0].vm_name : "absent"
    worker1_2   = length(module.worker1_2) > 0 ? module.worker1_2[0].vm_name : "absent"
    worker2_1   = length(module.worker2_1) > 0 ? module.worker2_1[0].vm_name : "absent"
    worker2_2   = length(module.worker2_2) > 0 ? module.worker2_2[0].vm_name : "absent"
    ruleset_sha = sha256(local.citus_nftables_ruleset)
    overlay_v   = "1"
  }

  depends_on = [
    module.etcd_1, module.etcd_2, module.etcd_3,
    module.coord_1, module.coord_2,
    module.worker1_1, module.worker1_2,
    module.worker2_1, module.worker2_2,
  ]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $ips     = @('${join("','", local.citus_node_ips)}')
      $user    = '${var.citus_node_user}'
      $timeout = ${var.citus_cluster_timeout_minutes}
      $sshOpts = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      $ruleset = @'
${local.citus_nftables_ruleset}
'@
      $ruleset = $ruleset -replace "`r`n","`n"

      if ($ips.Count -eq 0 -or $ips[0] -eq '') {
        Write-Host "[citus-nftables] no enabled citus-tier nodes -- nothing to do"
        exit 0
      }

      foreach ($ip in $ips) {
        Write-Host "[citus-nftables] $${ip}: waiting for SSH + firstboot marker..."
        $deadline = (Get-Date).AddMinutes($timeout)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
          $probe = (ssh @sshOpts "$user@$ip" "test -f /var/lib/citus-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
          if ($probe -match 'READY') { $ready = $true; break }
          Start-Sleep -Seconds 15
        }
        if (-not $ready) { throw "[citus-nftables] $${ip}: SSH + firstboot marker never ready after $timeout min" }

        Write-Host "[citus-nftables] $${ip}: pushing ruleset + nft -f"
        $remote = "tr -d '\r' | sudo tee /etc/nftables.conf > /dev/null && sudo nft -f /etc/nftables.conf && sudo systemctl enable nftables --now && echo NFT_OK"
        $out = ($ruleset | ssh @sshOpts "$user@$ip" $remote 2>&1 | Out-String)
        if ($out -notmatch 'NFT_OK') {
          throw "[citus-nftables] $${ip}: ruleset push/reload failed -- $out"
        }
        Write-Host "[citus-nftables] $${ip}: ruleset applied"
      }

      Write-Host "[citus-nftables] all $($ips.Count) citus-tier node(s) converged on the per-cluster ruleset"
    PWSH
  }
}
