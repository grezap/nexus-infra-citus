/*
 * role-overlay-citus-operator-user.tf -- Phase 0.P / nexus-cli v0.7.3
 *
 * One-shot: create the nexus-cli OPERATOR role on the Citus cluster (the
 * ADR-0011 Vault-KV operator-credential model, shared by every password-auth
 * adapter -- mongo/percona/patroni/clickhouse/starrocks/vitess). The CitusAdapter
 * (nexus-cli v0.7.3) authenticates as this role; its password lives ONLY in Vault
 * KV (nexus/citus/operator-password), read on-node via each node's Vault Agent.
 *
 *   1. Find the coordinator group's Patroni leader (patronictl).
 *   2. On the leader, read operator-password via the node's Vault Agent token,
 *      then CREATE ROLE nexus-cluster-admin (LOGIN CREATEROLE CREATEDB, NOT
 *      superuser) + GRANT pg_read_all_data,pg_write_all_data + GRANT ALL ON
 *      DATABASE <db> + ALL ON SCHEMA public. Citus auto-propagates the role to
 *      the workers (citus.enable_create_role_propagation).
 *   3. Append `*:5432:*:nexus-cluster-admin:<pw>` to ~postgres/.pgpass on BOTH
 *      coordinator nodes (0600 postgres:postgres) so the coordinator can dial
 *      the workers AS the operator -> distributed queries run end-to-end as the
 *      operator (the .pgpass holds only postgres + replicator otherwise).
 *   4. Verify: a distributed `SELECT count(*) FROM events` as the operator via
 *      the coordinator VIP returns the seeded count.
 *
 * Idempotent (CREATE ROLE IF NOT EXISTS via DO-block; .pgpass line de-duped).
 * Selective ops: var.enable_citus_operator_user. Pre-req: citus_distribute wired
 * + Vault KV nexus/citus/operator-password seeded (security creds-seed v2) + the
 * citus PG-node Vault Agent policy grants read on operator-password.
 */

resource "null_resource" "citus_operator_user" {
  count = var.enable_citus_operator_user ? 1 : 0

  triggers = {
    distribute_id         = length(null_resource.citus_distribute) > 0 ? null_resource.citus_distribute[0].id : "disabled"
    citus_db              = var.citus_database
    coord_vip             = var.citus_coordinator_vip
    citus_operator_user_v = "1" # v1 (0.7.3) = create nexus-cluster-admin + grants (propagates to workers) + .pgpass on both coord nodes.
    coord_probe_ip        = "192.168.70.205"
  }

  depends_on = [null_resource.citus_distribute]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.citus_node_user}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coordProbe = '192.168.70.205'
      $citusDb    = '${var.citus_database}'
      $coordVip   = '${var.citus_coordinator_vip}'
      $timeout    = ${var.citus_cluster_timeout_minutes}
      $coordHosts = @{ 'citus-coord-1' = '192.168.70.205'; 'citus-coord-2' = '192.168.70.206' }

      # Find the coordinator group's Patroni leader.
      $leaderHost = $null
      $deadline = (Get-Date).AddMinutes($timeout)
      while ((Get-Date) -lt $deadline -and -not $leaderHost) {
        $listOut = (ssh @sshOpts "$sshUser@$coordProbe" "sudo /usr/local/sbin/nexus-patronictl list --format json 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($listOut -match '\[') {
          try { $leader = ($listOut | ConvertFrom-Json | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1); if ($leader) { $leaderHost = $leader.Member } } catch { }
        }
        if (-not $leaderHost) { Start-Sleep -Seconds 5 }
      }
      if (-not $leaderHost) { throw "[citus-operator-user] could not find coordinator leader within $timeout min" }
      $leaderIp = $coordHosts[$leaderHost]
      Write-Host "[citus-operator-user] coordinator leader = $leaderHost ($leaderIp)"

      # Role-creation script (runs on the coordinator leader; reads the operator
      # password on-node via the Vault Agent token so it never transits the wire).
      $role = @"
set -euo pipefail
T=`$(sudo cat /run/nexus-vault-agent/token)
PW=`$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="`$T" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt /usr/local/bin/vault kv get -field=content nexus/citus/operator-password)
[ -n "`$PW" ] || { echo NO_PW; exit 1; }
pq() { sudo -u postgres psql -h /var/run/nexus-citus -U postgres -d '$citusDb' -v ON_ERROR_STOP=1 -tA -c "`$1"; }
pq "DO \`$do\`$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='nexus-cluster-admin') THEN CREATE ROLE \"nexus-cluster-admin\" LOGIN CREATEROLE CREATEDB PASSWORD '`$PW'; ELSE ALTER ROLE \"nexus-cluster-admin\" WITH LOGIN CREATEROLE CREATEDB PASSWORD '`$PW'; END IF; END \`$do\`$;"
pq "GRANT pg_read_all_data, pg_write_all_data TO \"nexus-cluster-admin\""
pq "GRANT ALL ON DATABASE $citusDb TO \"nexus-cluster-admin\""
pq "GRANT ALL ON SCHEMA public TO \"nexus-cluster-admin\""
echo OPERATOR_ROLE_OK
"@
      $roleOut = ($role -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $roleOut.Trim()
      if ($LASTEXITCODE -ne 0 -or $roleOut -notmatch 'OPERATOR_ROLE_OK') { throw "[citus-operator-user] role creation failed (rc=$LASTEXITCODE)" }

      # .pgpass entry on BOTH coordinator nodes (either may be leader after a
      # failover; the coordinator originates the worker connections).
      foreach ($ip in @('192.168.70.205','192.168.70.206')) {
        $pgp = @"
set -euo pipefail
T=`$(sudo cat /run/nexus-vault-agent/token)
PW=`$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="`$T" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt /usr/local/bin/vault kv get -field=content nexus/citus/operator-password)
[ -n "`$PW" ] || { echo NO_PW; exit 1; }
PGP=`$(getent passwd postgres | cut -d: -f6)/.pgpass
sudo touch "`$PGP"
sudo sed -i "/:nexus-cluster-admin:/d" "`$PGP" 2>/dev/null || true
echo "*:5432:*:nexus-cluster-admin:`$PW" | sudo tee -a "`$PGP" >/dev/null
sudo chown postgres:postgres "`$PGP"; sudo chmod 600 "`$PGP"
echo PGPASS_OK
"@
        $pgpOut = ($pgp -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$ip" "tr -d '\r' | bash -s" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $pgpOut -notmatch 'PGPASS_OK') { throw "[citus-operator-user] .pgpass update on $ip failed: $($pgpOut.Trim())" }
        Write-Host "[citus-operator-user] .pgpass updated on $ip"
      }

      # Verify a distributed query as the operator via the coordinator VIP.
      $verify = @"
T=`$(sudo cat /run/nexus-vault-agent/token)
PW=`$(sudo env VAULT_ADDR=https://192.168.70.121:8200 VAULT_TOKEN="`$T" VAULT_CACERT=/etc/vault-agent/ca-bundle.crt /usr/local/bin/vault kv get -field=content nexus/citus/operator-password)
sudo env PGPASSWORD="`$PW" psql "host=$coordVip port=5432 dbname=$citusDb user=nexus-cluster-admin sslmode=verify-ca sslrootcert=/etc/nexus-citus/tls/ca.pem sslcert=/etc/nexus-citus/tls/server-cert.pem sslkey=/etc/nexus-citus/tls/server-key.pem" -tAc 'SELECT '\''OPVERIFY='\'' || count(*) FROM events'
"@
      $vOut = ($verify -replace "`r`n","`n") | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $vOut.Trim()
      if ($vOut -notmatch 'OPVERIFY=\d+') { throw "[citus-operator-user] operator distributed-query verify failed: $($vOut.Trim())" }
      Write-Host "[citus-operator-user] operator nexus-cluster-admin ready (role propagated to workers, .pgpass on both coord nodes, distributed query OK)."
    PWSH
  }
}
