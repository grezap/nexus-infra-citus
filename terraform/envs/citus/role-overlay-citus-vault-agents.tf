/*
 * role-overlay-citus-vault-agents.tf -- Phase 0.P
 *
 * Installs Vault Agent as a `nexus-vault-agent` systemd service on each of the
 * 9 citus-tier clones (3 etcd + coordinator pair + 2 worker pairs). Direct port
 * of the 0.G.4 patroni-vault-agents overlay with 9 hosts + the citus-specific
 * sidecar prefix (`vault-agent-citus-`) + the citus firstboot marker.
 *
 * Cross-env coupling: reads the per-host AppRole JSON sidecars at
 * $HOME/.nexus/vault-agent-citus-<host>.json (written by
 * nexus-infra-vmware/terraform/envs/security/role-overlay-vault-agent-citus-
 * approles.tf). ERROR (not WARN+skip) if absent.
 *
 * Vault Agent config: directory mode (`-config=/etc/vault-agent/`) merges all
 * *.hcl at startup. This file writes 00-base.hcl (auto_auth approle + sink +
 * vault address). role-overlay-citus-tls.tf drops the PKI template stanza +
 * role-specific KV template stanzas without rewriting this file.
 *
 * Selective ops: var.enable_citus_vault_agents (master) AND per-host
 *                var.enable_<host>_vault_agent.
 */

locals {
  citus_vault_agent_specs = {
    "citus-etcd-1"    = { vm_ip = "192.168.70.202", enabled = var.enable_etcd_1_vault_agent }
    "citus-etcd-2"    = { vm_ip = "192.168.70.203", enabled = var.enable_etcd_2_vault_agent }
    "citus-etcd-3"    = { vm_ip = "192.168.70.204", enabled = var.enable_etcd_3_vault_agent }
    "citus-coord-1"   = { vm_ip = "192.168.70.205", enabled = var.enable_coord_1_vault_agent }
    "citus-coord-2"   = { vm_ip = "192.168.70.206", enabled = var.enable_coord_2_vault_agent }
    "citus-worker1-1" = { vm_ip = "192.168.70.207", enabled = var.enable_worker1_1_vault_agent }
    "citus-worker1-2" = { vm_ip = "192.168.70.208", enabled = var.enable_worker1_2_vault_agent }
    "citus-worker2-1" = { vm_ip = "192.168.70.209", enabled = var.enable_worker2_1_vault_agent }
    "citus-worker2-2" = { vm_ip = "192.168.70.210", enabled = var.enable_worker2_2_vault_agent }
  }

  citus_vault_agent_active = {
    for host, spec in local.citus_vault_agent_specs : host => spec
    if var.enable_citus_vault_agents && spec.enabled
  }

  citus_va_creds_dir_expanded = pathexpand(replace(var.vault_agent_citus_creds_dir, "$HOME", "~"))
  citus_va_ca_bundle_expanded = pathexpand(replace(var.vault_pki_ca_bundle_path, "$HOME", "~"))
}

resource "null_resource" "citus_vault_agent" {
  for_each = local.citus_vault_agent_active

  triggers = {
    creds_file_path    = "${local.citus_va_creds_dir_expanded}/vault-agent-citus-${each.key}.json"
    creds_file_hash    = filesha256("${local.citus_va_creds_dir_expanded}/vault-agent-citus-${each.key}.json")
    nftables_id        = length(null_resource.citus_nftables_backplane) > 0 ? null_resource.citus_nftables_backplane[0].id : "disabled"
    vault_version      = var.vault_agent_version
    citus_va_overlay_v = "1" # v1 (0.P) = 9 nodes (3 etcd + coord pair + 2 worker pairs).

    destroy_vm_ip    = each.value.vm_ip
    destroy_ssh_user = var.citus_node_user
  }

  depends_on = [null_resource.citus_nftables_backplane]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName     = '${each.key}'
      $vmIp         = '${each.value.vm_ip}'
      $vaultVersion = '${var.vault_agent_version}'
      $credsFile    = '${local.citus_va_creds_dir_expanded}/vault-agent-citus-${each.key}.json'
      $caBundlePath = '${local.citus_va_ca_bundle_expanded}'
      $sshUser      = '${var.citus_node_user}'
      $bootTimeout  = ${var.citus_cluster_timeout_minutes}

      if (-not (Test-Path $credsFile)) {
        throw "[citus-va $hostName] creds file $credsFile missing -- run nexus-infra-vmware/scripts/security.ps1 apply FIRST to provision the 9 citus AppRole sidecars."
      }
      $creds     = Get-Content $credsFile | ConvertFrom-Json
      $roleId    = $creds.role_id
      $secretId  = $creds.secret_id
      $vaultAddr = $creds.vault_addr
      if (-not $roleId -or -not $secretId) {
        throw "[citus-va $hostName] creds JSON missing role_id or secret_id"
      }
      if (-not (Test-Path $caBundlePath)) {
        throw "[citus-va $hostName] CA bundle $caBundlePath missing -- run security env apply (PKI distribute) first."
      }

      $sshOpts = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host "[citus-va $hostName] waiting for SSH + firstboot marker..."
      $bootDeadline = (Get-Date).AddMinutes($bootTimeout)
      $booted = $false
      while ((Get-Date) -lt $bootDeadline) {
        $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -f /var/lib/citus-node-firstboot-done && echo READY" 2>&1 | Out-String).Trim()
        if ($probe -match 'READY') { $booted = $true; break }
        Start-Sleep -Seconds 15
      }
      if (-not $booted) { throw "[citus-va $hostName] SSH + firstboot marker never ready after $bootTimeout min" }

      $probe = (ssh @sshOpts "$sshUser@$vmIp" "test -x /usr/local/bin/vault && /usr/local/bin/vault version 2>/dev/null && systemctl is-active nexus-vault-agent.service 2>/dev/null" 2>&1 | Out-String).Trim()
      if ($probe -match "Vault v$vaultVersion" -and $probe -match '(?m)^active$') {
        Write-Host "[citus-va $hostName] already installed at v$vaultVersion + service active; skipping."
        exit 0
      }

      Write-Host "[citus-va $hostName] installing Vault Agent v$vaultVersion"

      $installScript = @"
set -euo pipefail
if ! getent hosts releases.hashicorp.com >/dev/null 2>&1; then
  echo "[citus-va install] /etc/resolv.conf missing resolver; pointing at nexus-gateway dnsmasq"
  echo "nameserver 192.168.70.1" | sudo tee /etc/resolv.conf > /dev/null
fi

if [ -x /usr/local/bin/vault ] && /usr/local/bin/vault version 2>/dev/null | grep -qF "Vault v$vaultVersion"; then
  echo "vault binary v$vaultVersion already installed"
else
  # /var/tmp (on /) not tmpfs /tmp -- the etcd nodes are 1 GB RAM VMs.
  INSTALL_DIR=/var/tmp/nexus-vault-agent-install
  rm -rf "`$INSTALL_DIR"
  mkdir -p "`$INSTALL_DIR"
  cd "`$INSTALL_DIR"
  zip="vault_$${vaultVersion}_linux_amd64.zip"
  sums="vault_$${vaultVersion}_SHA256SUMS"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$zip"  -o "`$zip"
  curl -fsSL "https://releases.hashicorp.com/vault/$${vaultVersion}/`$sums" -o "`$sums"
  grep "`$zip" "`$sums" | sha256sum -c -
  unzip -o "`$zip"
  sudo install -m 755 -o root -g root vault /usr/local/bin/vault
  cd /
  rm -rf "`$INSTALL_DIR"
  echo "vault binary v$vaultVersion installed"
fi

sudo mkdir -p /etc/vault-agent /var/run/nexus-vault-agent /var/log/nexus-vault-agent
sudo chown root:root /etc/vault-agent
sudo chmod 0755 /etc/vault-agent
"@
      $installB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($installScript))
      $installOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$installB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $installOut.Trim()
        throw "[citus-va $hostName] vault binary install failed (rc=$LASTEXITCODE)"
      }
      Write-Host $installOut.Trim()

      $roleIdTmp   = New-TemporaryFile
      $secretIdTmp = New-TemporaryFile
      try {
        [System.IO.File]::WriteAllText($roleIdTmp.FullName, $roleId)
        [System.IO.File]::WriteAllText($secretIdTmp.FullName, $secretId)

        scp @sshOpts $roleIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/role-id"
        scp @sshOpts $secretIdTmp.FullName "$${sshUser}@$${vmIp}:/tmp/secret-id"
        scp @sshOpts $caBundlePath "$${sshUser}@$${vmIp}:/tmp/ca-bundle.crt"

        $stageScript = @"
set -euo pipefail
sudo install -m 0400 -o root -g root /tmp/role-id      /etc/vault-agent/role-id
sudo install -m 0400 -o root -g root /tmp/secret-id    /etc/vault-agent/secret-id
sudo install -m 0644 -o root -g root /tmp/ca-bundle.crt /etc/vault-agent/ca-bundle.crt
sudo rm -f /tmp/role-id /tmp/secret-id /tmp/ca-bundle.crt
"@
        $stageB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($stageScript))
        $stageOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$stageB64' | base64 -d | bash" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
          Write-Host $stageOut.Trim()
          throw "[citus-va $hostName] credential staging failed (rc=$LASTEXITCODE)"
        }
      } finally {
        Remove-Item $roleIdTmp.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $secretIdTmp.FullName -Force -ErrorAction SilentlyContinue
      }

      $baseConfig = @"
# 00-base.hcl -- Phase 0.P. auto_auth (approle) + sink + vault address.
# role-overlay-citus-tls.tf drops 70-template-citus-tls.hcl + KV template
# stanzas (71-* ...; pg nodes only) in this dir.

pid_file = "/var/run/nexus-vault-agent/agent.pid"

vault {
  address = "$vaultAddr"
  ca_cert = "/etc/vault-agent/ca-bundle.crt"
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault-agent/role-id"
      secret_id_file_path                 = "/etc/vault-agent/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }
  sink "file" {
    config = {
      path = "/var/run/nexus-vault-agent/token"
      mode = 0640
    }
  }
}
"@

      $unitFile = @"
[Unit]
Description=Nexus Vault Agent (Phase 0.P -- Citus PG + etcd mTLS + cluster creds)
Documentation=https://developer.hashicorp.com/vault/docs/agent
Requires=network-online.target
After=network-online.target citus-node-firstboot.service
ConditionFileIsExecutable=/usr/local/bin/vault
StartLimitBurst=15
StartLimitIntervalSec=600

[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=nexus-vault-agent
RuntimeDirectoryMode=0755
LogsDirectory=nexus-vault-agent
LogsDirectoryMode=0755
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent/
ExecReload=/bin/kill -HUP `$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
StandardOutput=append:/var/log/nexus-vault-agent/agent.log
StandardError=append:/var/log/nexus-vault-agent/agent.log

[Install]
WantedBy=multi-user.target
"@

      $configB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($baseConfig))
      $unitB64   = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($unitFile))

      $finalScript = @"
set -euo pipefail
echo '$configB64' | base64 -d | sudo tee /etc/vault-agent/00-base.hcl > /dev/null
sudo chown root:root /etc/vault-agent/00-base.hcl
sudo chmod 0644 /etc/vault-agent/00-base.hcl

echo '$unitB64' | base64 -d | sudo tee /etc/systemd/system/nexus-vault-agent.service > /dev/null
sudo chown root:root /etc/systemd/system/nexus-vault-agent.service
sudo chmod 0644 /etc/systemd/system/nexus-vault-agent.service

sudo systemctl daemon-reload
sudo systemctl enable --now nexus-vault-agent.service
"@
      $finalB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($finalScript))
      $finalOut = ssh @sshOpts "$sshUser@$vmIp" "echo '$finalB64' | base64 -d | bash" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0) {
        Write-Host $finalOut.Trim()
        throw "[citus-va $hostName] config/service setup failed (rc=$LASTEXITCODE)"
      }
      Write-Host $finalOut.Trim()

      Start-Sleep -Seconds 5
      $verifyDeadline = (Get-Date).AddSeconds(30)
      $serviceActive = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $status = (ssh @sshOpts "$sshUser@$vmIp" "systemctl is-active nexus-vault-agent.service" 2>&1 | Out-String).Trim()
        if ($status -eq 'active') { $serviceActive = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $serviceActive) {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[citus-va $hostName] nexus-vault-agent.service failed to reach active within 30s"
      }
      Write-Host "[citus-va $hostName] nexus-vault-agent.service active"

      $tokenCheck = (ssh @sshOpts "$sshUser@$vmIp" "sudo test -s /var/run/nexus-vault-agent/token && echo TOKEN_PRESENT" 2>&1 | Out-String).Trim()
      if ($tokenCheck -notmatch 'TOKEN_PRESENT') {
        $journal = (ssh @sshOpts "$sshUser@$vmIp" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 30" 2>&1 | Out-String)
        Write-Host $journal
        throw "[citus-va $hostName] AppRole login appears to have failed (token sink empty)"
      }
      Write-Host "[citus-va $hostName] AppRole authenticated; token sink populated"
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
      Write-Host "[citus-va destroy] $${hostName}: stopping nexus-vault-agent + cleaning install-owned files (keeping /etc/vault-agent/ + TLS/KV templates)"
      ssh @sshOpts "$sshUser@$vmIp" "sudo systemctl disable --now nexus-vault-agent.service 2>/dev/null; sudo rm -f /etc/vault-agent/00-base.hcl /etc/vault-agent/role-id /etc/vault-agent/secret-id /etc/vault-agent/ca-bundle.crt /etc/systemd/system/nexus-vault-agent.service; sudo systemctl daemon-reload" 2>$null
      exit 0
    PWSH
  }
}
