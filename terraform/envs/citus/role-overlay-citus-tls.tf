/*
 * role-overlay-citus-tls.tf -- Phase 0.P -- per-host PKI leaf + (pg only) KV
 * cred renders for all 9 citus-tier nodes, via each host's Vault Agent.
 *
 * Two roles differ in destination path + KV set + key ownership:
 *   - etcd nodes: dest /etc/nexus-etcd/tls (group etcd); NO KV creds (etcd uses
 *     client-cert-auth as the access control, no password); key 0640 root:etcd.
 *   - pg nodes (coordinator + workers): dest /etc/nexus-citus/tls (group
 *     postgres); KV set = superuser + replication + patroni-restapi + citus-app;
 *     key 0600 postgres:postgres. The 0600/postgres-owned key matters because
 *     the coordinator's `citus.node_conninfo` uses libpq as a CLIENT to dial
 *     workers, and libpq REJECTS a client key that is group/world-readable or
 *     not owned by the connecting user -- a 0640 root:postgres key (the
 *     server-only convention) would fail the client path. 0600 postgres:postgres
 *     satisfies BOTH the PG server and the libpq client.
 *
 * VIP IP-SAN + VIP DNS name: each pg node carries ITS GROUP'S VIP in the cert
 * (coord -> .211 / coord.citus.nexus.lab; worker1 -> .212 / worker1...; worker2
 * -> .213 / worker2...). The VIP floats between the group's 2 nodes, and the
 * coordinator dials workers by the VIP with sslmode=verify-full, so whichever
 * leader holds the VIP must present a cert covering it. etcd nodes never hold a
 * VIP, so their certs only cover their own IPs.
 *
 * The PKI cert is rendered by the Vault Agent `pkiCert` template into
 * tls/bundle.pem, then split into server-cert/server-key/ca by a single
 * /usr/local/sbin/nexus-citus-tls-split.sh <dest-dir> <role>.
 *
 * Selective ops: var.enable_citus_tls AND var.enable_citus_vault_agents.
 */

locals {
  citus_tls_per_host = {
    "citus-etcd-1"    = { vmnet10 = "192.168.10.202", vmnet11 = "192.168.70.202", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "", vip_dns = "" }
    "citus-etcd-2"    = { vmnet10 = "192.168.10.203", vmnet11 = "192.168.70.203", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "", vip_dns = "" }
    "citus-etcd-3"    = { vmnet10 = "192.168.10.204", vmnet11 = "192.168.70.204", role = "etcd", config_dir = "/etc/nexus-etcd", owner_group = "etcd", vip = "", vip_dns = "" }
    "citus-coord-1"   = { vmnet10 = "192.168.10.205", vmnet11 = "192.168.70.205", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_coordinator_vip, vip_dns = "coord.citus.nexus.lab" }
    "citus-coord-2"   = { vmnet10 = "192.168.10.206", vmnet11 = "192.168.70.206", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_coordinator_vip, vip_dns = "coord.citus.nexus.lab" }
    "citus-worker1-1" = { vmnet10 = "192.168.10.207", vmnet11 = "192.168.70.207", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_worker1_vip, vip_dns = "worker1.citus.nexus.lab" }
    "citus-worker1-2" = { vmnet10 = "192.168.10.208", vmnet11 = "192.168.70.208", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_worker1_vip, vip_dns = "worker1.citus.nexus.lab" }
    "citus-worker2-1" = { vmnet10 = "192.168.10.209", vmnet11 = "192.168.70.209", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_worker2_vip, vip_dns = "worker2.citus.nexus.lab" }
    "citus-worker2-2" = { vmnet10 = "192.168.10.210", vmnet11 = "192.168.70.210", role = "pg", config_dir = "/etc/nexus-citus", owner_group = "postgres", vip = var.citus_worker2_vip, vip_dns = "worker2.citus.nexus.lab" }
  }

  citus_tls_active = {
    for host, spec in local.citus_tls_per_host : host => spec
    if(
      var.enable_citus_tls && var.enable_citus_vault_agents
      && lookup(local.citus_vault_agent_active, host, null) != null
    )
  }
}

resource "null_resource" "citus_tls" {
  for_each = local.citus_tls_active

  triggers = {
    va_id         = null_resource.citus_vault_agent[each.key].id
    pki_role_name = var.vault_pki_citus_role_name
    vmnet10       = each.value.vmnet10
    vmnet11       = each.value.vmnet11
    role          = each.value.role
    config_dir    = each.value.config_dir
    owner_group   = each.value.owner_group
    vip           = each.value.vip
    vip_dns       = each.value.vip_dns
    citus_tls_v   = "1" # v1 (0.P) = 9 nodes (3 etcd + coord pair + 2 worker pairs); pg nodes carry group VIP in IP-SANs + VIP DNS in alt_names.

    destroy_vm_ip    = each.value.vmnet11
    destroy_ssh_user = var.citus_node_user
  }

  depends_on = [null_resource.citus_vault_agent]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName   = '${each.key}'
      $ip         = '${each.value.vmnet11}'
      $vmnet10    = '${each.value.vmnet10}'
      $role       = '${each.value.role}'
      $configDir  = '${each.value.config_dir}'
      $ownerGroup = '${each.value.owner_group}'
      $vip        = '${each.value.vip}'
      $vipDns     = '${each.value.vip_dns}'
      $pkiRole    = '${var.vault_pki_citus_role_name}'
      $sshUser    = '${var.citus_node_user}'
      $cn         = "$hostName.citus.nexus.lab"
      # pg nodes carry their group VIP DNS name in alt_names + the VIP IP in
      # ip_sans (so verify-full against the VIP validates regardless of which
      # node holds it). etcd nodes never hold a VIP.
      if ($vipDns) {
        $altNames = "$hostName,$hostName.nexus.lab,$hostName.citus.nexus.lab,$vipDns,localhost"
        $ipSans   = "$vmnet10,$ip,$vip,127.0.0.1"
      } else {
        $altNames = "$hostName,$hostName.nexus.lab,$hostName.citus.nexus.lab,localhost"
        $ipSans   = "$vmnet10,$ip,127.0.0.1"
      }
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')

      Write-Host ""
      Write-Host "[citus-tls $hostName] cert render + (pg) KV cred renders via Vault Agent (role=$role, configDir=$configDir, ipSans=$ipSans)"

      # ─── Split script (single-quoted literal) -- takes destDir + role ─────
      # role=pg  : key 0600 postgres:postgres (PG server AND libpq client ok);
      #            cert/ca 0644 root:postgres.
      # role=etcd: key 0640 root:etcd; cert/ca 0640 root:etcd.
      $splitScript = @'
#!/bin/bash
set -euo pipefail
DEST="$${1:?usage: nexus-citus-tls-split.sh <dest-dir> <role>}"
ROLE="$${2:?usage: nexus-citus-tls-split.sh <dest-dir> <role>}"
BUNDLE="$DEST/bundle.pem"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

awk -v tmp="$TMP" '
  /-----BEGIN/ { n++; file=tmp"/block-"n }
  { if (n>0) print > file }
' "$BUNDLE"

LEAF=""
KEY=""
CA=""
for f in "$TMP"/block-*; do
  hdr=$(head -1 "$f")
  case "$hdr" in
    *"PRIVATE KEY"*)
      KEY=$f
      ;;
    *"BEGIN CERTIFICATE"*)
      if [ -z "$LEAF" ]; then LEAF=$f; else CA=$f; fi
      ;;
  esac
done

if [ -z "$LEAF" ] || [ -z "$KEY" ] || [ -z "$CA" ]; then
  echo "[citus-tls-split] ERROR: bundle missing one of leaf/key/ca" >&2
  ls -la "$TMP" >&2
  exit 1
fi

openssl pkcs8 -topk8 -nocrypt -in "$KEY" -out "$TMP/key-pkcs8.pem"

cat "$LEAF" > "$TMP/server-cert.pem"
cat "$TMP/key-pkcs8.pem" > "$TMP/server-key.pem"

ROOT_BUNDLE=/etc/vault-agent/ca-bundle.crt
if [ ! -s "$ROOT_BUNDLE" ]; then
  echo "[citus-tls-split] ERROR: $ROOT_BUNDLE missing -- Vault Agent must be installed first" >&2
  exit 1
fi
cat "$CA" "$ROOT_BUNDLE" > "$TMP/ca.pem"

if [ "$ROLE" = "pg" ]; then
  # 0600 postgres:postgres key satisfies BOTH the PG server and the libpq
  # client (citus.node_conninfo dials workers). Certs are public -> 0644.
  install -m 0644 -o root     -g postgres "$TMP/server-cert.pem" "$DEST/server-cert.pem"
  install -m 0600 -o postgres -g postgres "$TMP/server-key.pem"  "$DEST/server-key.pem"
  install -m 0644 -o root     -g postgres "$TMP/ca.pem"          "$DEST/ca.pem"
else
  # etcd reads via group etcd.
  install -m 0640 -o root -g etcd "$TMP/server-cert.pem" "$DEST/server-cert.pem"
  install -m 0640 -o root -g etcd "$TMP/server-key.pem"  "$DEST/server-key.pem"
  install -m 0640 -o root -g etcd "$TMP/ca.pem"          "$DEST/ca.pem"
fi

install -m 0644 -o root -g root "$TMP/ca.pem" /etc/ssl/certs/citus-ca.pem

echo "[citus-tls-split] $(date -u +%FT%TZ) bundle split into $DEST (role=$ROLE)"
'@

      $splitB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($splitScript -replace "`r`n","`n")))

      # ─── 70-template-citus-tls.hcl -- per-host PKI leaf ───────────────────
      $vaultTlsTemplate = @"
# 70-template-citus-tls.hcl -- Phase 0.P (rendered for $hostName, role=$role).

template {
  contents = <<EOT
{{- with pkiCert `"pki_int/issue/$pkiRole`" `"common_name=$cn`" `"alt_names=$altNames`" `"ip_sans=$ipSans`" `"ttl=2160h`" }}
{{ .Cert }}
{{ .Key }}
{{ .CA }}
{{- end }}
EOT

  destination     = "$configDir/tls/bundle.pem"
  perms           = "0640"
  user            = "root"
  group           = "$ownerGroup"
  command         = "/usr/local/sbin/nexus-citus-tls-split.sh $configDir/tls $role"
  command_timeout = "30s"
}
"@
      $vaTlsB64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($vaultTlsTemplate -replace "`r`n","`n")))

      # ─── KV template builder (pg role only) ───────────────────────────────
      function New-KvTemplate {
        param([string]$Path, [string]$Dest, [string]$OwnerGroup)
        @"
template {
  contents = <<EOT
{{- with secret `"$Path`" }}{{ .Data.data.content }}{{- end }}
EOT

  destination = "$Dest"
  perms       = "0400"
  user        = "root"
  group       = "$OwnerGroup"
}
"@
      }

      # pg nodes render the 4 PG creds; etcd nodes render none.
      $kvTemplates = @()
      if ($role -eq 'pg') {
        $kvTemplates += @{ File = '71-template-superuser.hcl';     Body = (New-KvTemplate 'nexus/data/citus/superuser-password'       "$configDir/superuser-password"       $ownerGroup); Dest = "$configDir/superuser-password" }
        $kvTemplates += @{ File = '72-template-replication.hcl';   Body = (New-KvTemplate 'nexus/data/citus/replication-password'     "$configDir/replication-password"     $ownerGroup); Dest = "$configDir/replication-password" }
        $kvTemplates += @{ File = '73-template-patroni-rest.hcl';  Body = (New-KvTemplate 'nexus/data/citus/patroni-restapi-password' "$configDir/patroni-restapi-password" $ownerGroup); Dest = "$configDir/patroni-restapi-password" }
        $kvTemplates += @{ File = '74-template-citus-app.hcl';     Body = (New-KvTemplate 'nexus/data/citus/citus-app-password'       "$configDir/citus-app-password"       $ownerGroup); Dest = "$configDir/citus-app-password" }
      }

      $kvDropLines = @()
      $kvWaitLines = @()
      $kvErrLines  = @()
      foreach ($t in $kvTemplates) {
        $b64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes(($t.Body -replace "`r`n","`n")))
        $kvDropLines += "echo '$b64' | base64 -d | sudo tee /etc/vault-agent/$($t.File) > /dev/null"
        $kvDropLines += "sudo chown root:root /etc/vault-agent/$($t.File)"
        $kvDropLines += "sudo chmod 0644 /etc/vault-agent/$($t.File)"
        $kvWaitLines += "&& sudo test -s $($t.Dest)"
        $kvErrLines  += "if ! sudo test -s $($t.Dest); then echo '[citus-tls stage] ERROR: $($t.Dest) not rendered within 20s' >&2; sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2; exit 1; fi"
      }
      $kvDropBody = ($kvDropLines -join "`n")
      # Join wait-conditions with a single space (NOT bash line-continuation):
      # PS double-quoted backslash renders as TWO backslashes -> bash literal,
      # breaking `&&`. (0.G.4 transient #5.)
      $kvWaitBody = ($kvWaitLines -join " ")
      $kvErrBody  = ($kvErrLines  -join "`n")

      $stage = @"
set -euo pipefail

# Pre-flight: role user/group must exist (apt-installed by Packer; defensive).
if [ '$role' = 'pg' ]; then
  if ! getent group postgres >/dev/null; then sudo groupadd --system postgres; fi
  if ! getent passwd postgres >/dev/null; then sudo useradd --system --gid postgres --no-create-home --shell /usr/sbin/nologin postgres; fi
else
  if ! getent group etcd >/dev/null; then sudo groupadd --system etcd; fi
  if ! getent passwd etcd >/dev/null; then sudo useradd --system --gid etcd --no-create-home --shell /usr/sbin/nologin etcd; fi
fi

sudo mkdir -p $configDir/tls
sudo chown root:$ownerGroup $configDir $configDir/tls
sudo chmod 0750 $configDir $configDir/tls

echo '$splitB64' | base64 -d | sudo tee /usr/local/sbin/nexus-citus-tls-split.sh > /dev/null
sudo chown root:root /usr/local/sbin/nexus-citus-tls-split.sh
sudo chmod 0755 /usr/local/sbin/nexus-citus-tls-split.sh

echo '$vaTlsB64' | base64 -d | sudo tee /etc/vault-agent/70-template-citus-tls.hcl > /dev/null
sudo chown root:root /etc/vault-agent/70-template-citus-tls.hcl
sudo chmod 0644 /etc/vault-agent/70-template-citus-tls.hcl

$kvDropBody

sudo systemctl restart nexus-vault-agent.service

# Wait for the cert bundle (+ any KV targets), then invoke split manually.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if sudo test -s $configDir/tls/bundle.pem $kvWaitBody; then break; fi
  sleep 2
done
if ! sudo test -s $configDir/tls/bundle.pem; then
  echo "[citus-tls stage] ERROR: bundle.pem not rendered within 20s after vault-agent restart" >&2
  sudo journalctl -u nexus-vault-agent.service --no-pager -n 20 >&2
  exit 1
fi
$kvErrBody
sudo /usr/local/sbin/nexus-citus-tls-split.sh $configDir/tls $role
echo STAGE_OK
"@
      $stageLf  = $stage -replace "`r`n", "`n"
      $stageOut = $stageLf | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
      if ($LASTEXITCODE -ne 0 -or $stageOut -notmatch 'STAGE_OK') {
        Write-Host $stageOut.Trim()
        throw "[citus-tls $hostName] cert + KV creds render stage failed (rc=$LASTEXITCODE)"
      }

      # Verify 3 split TLS files + (pg) KV secrets + CN.
      $kvCheckArgs = if ($kvTemplates.Count -gt 0) { " && " + (($kvTemplates | ForEach-Object { "sudo test -s $($_.Dest)" }) -join " && ") } else { "" }
      $verifyDeadline = (Get-Date).AddSeconds(60)
      $rendered = $false
      while ((Get-Date) -lt $verifyDeadline) {
        $check = (ssh @sshOpts "$sshUser@$ip" "sudo test -s $configDir/tls/server-cert.pem && sudo test -s $configDir/tls/server-key.pem && sudo test -s $configDir/tls/ca.pem$kvCheckArgs && sudo openssl x509 -in $configDir/tls/server-cert.pem -noout -subject 2>/dev/null | grep -q '$cn' && echo OK" 2>&1 | Out-String).Trim()
        if ($check -match 'OK') { $rendered = $true; break }
        Start-Sleep -Seconds 3
      }
      if (-not $rendered) {
        $journal = (ssh @sshOpts "$sshUser@$ip" "sudo journalctl -u nexus-vault-agent.service --no-pager -n 40" 2>&1 | Out-String)
        Write-Host $journal
        throw "[citus-tls $hostName] cert + KV secrets not rendered (CN=$cn) within 60s"
      }
      Write-Host "[citus-tls $hostName] rendered: server-cert.pem (CN=$cn) + server-key.pem (PKCS#8) + ca.pem (intermediate+root) + $($kvTemplates.Count) KV secrets"
    PWSH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $hostName  = '${each.key}'
      $vmIp      = '${self.triggers.destroy_vm_ip}'
      $configDir = '${self.triggers.config_dir}'
      $sshUser   = '${self.triggers.destroy_ssh_user}'
      $sshOpts   = @('-o','ConnectTimeout=5','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      Write-Host "[citus-tls destroy] $${hostName}: removing 70-74 templates + cert/keys + KV secret files + restarting vault-agent"
      ssh @sshOpts "$sshUser@$vmIp" "sudo rm -f /etc/vault-agent/70-template-citus-tls.hcl /etc/vault-agent/71-template-*.hcl /etc/vault-agent/72-template-*.hcl /etc/vault-agent/73-template-*.hcl /etc/vault-agent/74-template-*.hcl $configDir/tls/bundle.pem $configDir/tls/server-cert.pem $configDir/tls/server-key.pem $configDir/tls/ca.pem $configDir/superuser-password $configDir/replication-password $configDir/patroni-restapi-password $configDir/citus-app-password /etc/ssl/certs/citus-ca.pem; sudo systemctl restart nexus-vault-agent.service 2>/dev/null" 2>$null
      exit 0
    PWSH
  }
}
