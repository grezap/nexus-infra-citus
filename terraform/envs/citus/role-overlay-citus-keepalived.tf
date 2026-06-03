/*
 * role-overlay-citus-keepalived.tf -- Phase 0.P -- VRRP VIP per Patroni group.
 *
 * Runs ON the 6 PG nodes (keepalived co-located, NOT a separate LB pair). One
 * VRRP instance per node-group; the VIP floats to the group's current Patroni
 * LEADER because the vrrp_script curls the LOCAL Patroni REST /leader endpoint
 * (HTTP 200 only on the leader, 503 on replicas). Both nodes start at base
 * priority 100; the leader's passing check adds weight +50 -> effective 150 ->
 * holds the VIP. On Patroni failover the new leader's /leader flips to 200, its
 * priority jumps to 150, and the VIP moves -- no static MASTER/BACKUP needed.
 *
 *   coord group:   citus-coord-1/2    VIP .211  vrid 211  VI_CITUS_COORD
 *   worker1 group: citus-worker1-1/2  VIP .212  vrid 212  VI_CITUS_WORKER1
 *   worker2 group: citus-worker2-1/2  VIP .213  vrid 213  VI_CITUS_WORKER2
 *
 * Unicast VRRP (VMware VMnet multicast doesn't traverse reliably -- the 0.G.3
 * transient #22 lesson). The vrrp_script references the LOCAL curl by absolute
 * path through a check script (per the keepalived-needs-versioned-binary
 * lesson; we wrap the probe in a script rather than inlining a fragile binary
 * path). AH auth password derived from the shared patroni-restapi-password.
 *
 * Selective ops: var.enable_keepalived AND var.enable_patroni_bootstrap.
 */

locals {
  citus_keepalived_per_host = {
    "citus-coord-1"   = { vmnet11 = "192.168.70.205", peer = "192.168.70.206", vip = var.citus_coordinator_vip, vrid = "211", instance = "VI_CITUS_COORD" }
    "citus-coord-2"   = { vmnet11 = "192.168.70.206", peer = "192.168.70.205", vip = var.citus_coordinator_vip, vrid = "211", instance = "VI_CITUS_COORD" }
    "citus-worker1-1" = { vmnet11 = "192.168.70.207", peer = "192.168.70.208", vip = var.citus_worker1_vip, vrid = "212", instance = "VI_CITUS_WORKER1" }
    "citus-worker1-2" = { vmnet11 = "192.168.70.208", peer = "192.168.70.207", vip = var.citus_worker1_vip, vrid = "212", instance = "VI_CITUS_WORKER1" }
    "citus-worker2-1" = { vmnet11 = "192.168.70.209", peer = "192.168.70.210", vip = var.citus_worker2_vip, vrid = "213", instance = "VI_CITUS_WORKER2" }
    "citus-worker2-2" = { vmnet11 = "192.168.70.210", peer = "192.168.70.209", vip = var.citus_worker2_vip, vrid = "213", instance = "VI_CITUS_WORKER2" }
  }

  citus_keepalived_active = {
    for host, spec in local.citus_keepalived_per_host : host => spec
    if(
      var.enable_keepalived && var.enable_patroni_bootstrap
      && lookup(local.citus_pg_nodes_active, host, null) != null
    )
  }
}

resource "null_resource" "citus_keepalived" {
  for_each = local.citus_keepalived_active

  triggers = {
    patroni_id   = null_resource.citus_patroni_bootstrap[0].id
    vmnet11      = each.value.vmnet11
    vip          = each.value.vip
    vrid         = each.value.vrid
    instance     = each.value.instance
    peer_ip      = each.value.peer
    keepalived_v = "1" # v1 (0.P) = per-group unicast VRRP; VIP follows Patroni leader via /leader vrrp_script (weight +50).

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.citus_node_user
  }

  depends_on = [null_resource.citus_patroni_bootstrap]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $ip       = '${each.value.vmnet11}'
      $peerIp   = '${each.value.peer}'
      $vip      = '${each.value.vip}'
      $vrid     = '${each.value.vrid}'
      $instance = '${each.value.instance}'
      $sshUser  = '${var.citus_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[citus-keepalived $hostName] configuring $instance (vrid=$vrid, vip=$vip, leader-following)..."

      # AH auth password derived from the shared patroni-restapi-password (8
      # chars per VRRP spec). Both nodes in the group share it.
      $restPwd = (ssh @sshOpts "$sshUser@$ip" 'sudo cat /etc/nexus-citus/patroni-restapi-password' | Out-String).Trim()
      if (-not $restPwd -or $restPwd.Length -lt 16) {
        throw "[citus-keepalived $hostName] patroni-restapi-password missing -- citus-tls overlay must have run first."
      }
      $vrrpAuthPwd = $restPwd.Substring(0, 8)

      # ─── Leader-probe check script ───────────────────────────────────────
      # Patroni REST /leader returns 200 ONLY on the current leader (503 on
      # replicas). curl validates the local REST cert via ca.pem (127.0.0.1 is
      # an IP-SAN on every node cert). Absolute-path script (not an inlined
      # binary) per the keepalived-versioned-binary lesson.
      $checkScript = @'
#!/bin/bash
# Phase 0.P -- keepalived VRRP leader-follow check. Exit 0 only if this node is
# the current Patroni leader (REST /leader -> 200).
set -e
code=$(curl -s -o /dev/null -w '%%{http_code}' --cacert /etc/nexus-citus/tls/ca.pem https://127.0.0.1:8008/leader 2>/dev/null || echo 000)
if [ "$code" = "200" ]; then exit 0; fi
exit 1
'@
      $checkScriptB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($checkScript -replace "`r`n","`n")))

      # ─── keepalived.conf ─────────────────────────────────────────────────
      $kpConf = @"
# Generated by nexus-infra-citus/terraform/envs/citus/role-overlay-citus-keepalived.tf
# Phase 0.P -- VRRP VIP follows the Patroni leader for group on $hostName.
# DO NOT EDIT BY HAND.

global_defs {
  router_id citus_nexus_$hostName
  enable_script_security
  script_user root
}

vrrp_script chk_citus_leader {
  script   "/etc/keepalived/check_citus_leader.sh"
  interval 2
  timeout  3
  rise     1
  fall     2
  weight   50
}

vrrp_instance $instance {
  state         BACKUP
  interface     nic0
  virtual_router_id $vrid
  priority      100
  advert_int    1
  nopreempt

  # Unicast VRRP -- VMware VMnet11 multicast doesn't reliably forward between
  # guests (0.G.3 transient #22). Advertisements go directly to the peer.
  unicast_src_ip $ip
  unicast_peer {
    $peerIp
  }

  authentication {
    auth_type AH
    auth_pass $vrrpAuthPwd
  }

  virtual_ipaddress {
    $vip/24 dev nic0 label nic0:vip
  }

  track_script {
    chk_citus_leader
  }
}
"@
      $kpConfB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($kpConf -replace "`r`n","`n")))

      $stage = @"
set -euo pipefail
sudo install -d -o root -g root -m 0750 /etc/keepalived

echo '$checkScriptB64' | base64 -d | sudo tee /etc/keepalived/check_citus_leader.sh > /dev/null
sudo chown root:root /etc/keepalived/check_citus_leader.sh
sudo chmod 0700 /etc/keepalived/check_citus_leader.sh

echo '$kpConfB64' | base64 -d | sudo tee /etc/keepalived/keepalived.conf > /dev/null
sudo chown root:root /etc/keepalived/keepalived.conf
sudo chmod 0640 /etc/keepalived/keepalived.conf

sudo systemctl daemon-reload
sudo systemctl enable nexus-keepalived.service
sudo systemctl restart nexus-keepalived.service
echo KEEPALIVED_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'KEEPALIVED_OK') {
        Write-Host $stageOut.Trim()
        throw "[citus-keepalived $hostName] config / service start failed (rc=$LASTEXITCODE)"
      }

      Write-Host "[citus-keepalived $hostName] waiting for nexus-keepalived.service active..."
      $deadline = (Get-Date).AddMinutes(2)
      $active = $false
      while ((Get-Date) -lt $deadline) {
        $st = (ssh @sshOpts "$sshUser@$ip" "systemctl is-active nexus-keepalived.service" 2>&1 | Out-String).Trim()
        if ($st -eq 'active') { $active = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $active) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-keepalived.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[citus-keepalived $hostName] nexus-keepalived.service did not reach active within 2 min"
      }
      Write-Host "[citus-keepalived $hostName] active -- VIP $vip will bind on whichever group node is the Patroni leader."
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName = '${each.key}'
      $vmIp     = '${self.triggers.destroy_vm_ip}'
      $sshUser  = '${self.triggers.destroy_ssh_user}'
      $sshOpts  = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[citus-keepalived destroy] $${hostName}: stopping keepalived + removing config + check script"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-keepalived.service 2>/dev/null; sudo rm -f /etc/keepalived/keepalived.conf /etc/keepalived/check_citus_leader.sh" 2>$null
      exit 0
    PWSH
  }
}
