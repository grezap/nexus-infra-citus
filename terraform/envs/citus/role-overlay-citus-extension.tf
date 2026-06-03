/*
 * role-overlay-citus-extension.tf -- Phase 0.P
 *
 * One-shot: wire the Citus distributed cluster. Finds the coordinator group's
 * Patroni LEADER, then from there:
 *   1. CREATE DATABASE <citus_db> + CREATE EXTENSION citus on the coordinator
 *      AND on each worker leader (reached via the worker VIP over verify-full
 *      mTLS; postgres auth via ~postgres/.pgpass).
 *   2. citus_set_coordinator_host('coord.citus.nexus.lab', 5432) so workers can
 *      call back to the coordinator by its (failover-stable) VIP.
 *   3. citus_add_node('worker1.citus.nexus.lab', 5432) + worker2 -- registering
 *      each worker BY ITS VIP so a worker Patroni failover needs no pg_dist_node
 *      rewrite (the VIP moves to the new leader, the cert covers the VIP).
 *   4. CREATE ROLE citus_app (LOGIN, KV-seeded password) -- Citus auto-
 *      propagates the role to the workers; GRANT on the distributed database.
 *
 * Idempotent throughout (IF NOT EXISTS / pg_dist_node probes). Runs after
 * keepalived so all 3 VIPs are bound to their leaders.
 *
 * Selective ops: var.enable_citus_extension. Pre-req: 3 Patroni groups
 * converged + keepalived VIPs bound.
 */

resource "null_resource" "citus_extension" {
  count = var.enable_citus_extension ? 1 : 0

  triggers = {
    keepalived_ids    = join(",", [for host in keys(local.citus_keepalived_active) : null_resource.citus_keepalived[host].id])
    coord_vip         = var.citus_coordinator_vip
    worker1_vip       = var.citus_worker1_vip
    worker2_vip       = var.citus_worker2_vip
    citus_db          = var.citus_database
    citus_extension_v = "1" # v1 (0.P) = CREATE EXTENSION citus + set_coordinator_host + add 2 workers (by VIP) + citus_app role.
    coord_probe_ip    = "192.168.70.205"
  }

  depends_on = [null_resource.citus_keepalived]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser  = '${var.citus_node_user}'
      $sshOpts  = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coordProbe = '192.168.70.205'
      $citusDb  = '${var.citus_database}'
      $coordVip = '${var.citus_coordinator_vip}'
      $w1Vip    = '${var.citus_worker1_vip}'
      $w2Vip    = '${var.citus_worker2_vip}'
      $timeout  = ${var.citus_cluster_timeout_minutes}

      # ─── Find the coordinator group's Patroni leader ─────────────────────
      Write-Host "[citus-extension] locating coordinator leader via patronictl..."
      $coordHosts = @{ 'citus-coord-1' = '192.168.70.205'; 'citus-coord-2' = '192.168.70.206' }
      $leaderHost = $null
      $deadline = (Get-Date).AddMinutes($timeout)
      while ((Get-Date) -lt $deadline -and -not $leaderHost) {
        $listOut = (ssh @sshOpts "$sshUser@$coordProbe" "sudo /usr/local/sbin/nexus-patronictl list --format json 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($listOut -match '\[') {
          try {
            $cluster = $listOut | ConvertFrom-Json
            $leader  = $cluster | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1
            if ($leader) { $leaderHost = $leader.Member }
          } catch { }
        }
        if (-not $leaderHost) { Start-Sleep -Seconds 5 }
      }
      if (-not $leaderHost) { throw "[citus-extension] could not find coordinator leader within $timeout min" }
      $leaderIp = $coordHosts[$leaderHost]
      Write-Host "[citus-extension] coordinator leader = $leaderHost ($leaderIp)"

      # ─── Wiring script (runs on the coordinator leader) ──────────────────
      $wire = @"
set -euo pipefail
SOCK=/var/run/nexus-citus
CITUS_DB='$citusDb'
TLS="sslmode=verify-full sslrootcert=/etc/nexus-citus/tls/ca.pem sslcert=/etc/nexus-citus/tls/server-cert.pem sslkey=/etc/nexus-citus/tls/server-key.pem"
APP_PWD=`$(sudo cat /etc/nexus-citus/citus-app-password)

pq_local() { sudo -u postgres psql -h "`$SOCK" -U postgres -d "`$1" -v ON_ERROR_STOP=1 -tA -c "`$2"; }
pq_remote() { sudo -u postgres psql "host=`$1 port=5432 dbname=`$2 user=postgres `$TLS" -v ON_ERROR_STOP=1 -tA -c "`$3"; }

# Wait until a VIP points at a READ-WRITE primary (pg_is_in_recovery() = f).
# keepalived has just started, so the VIP can briefly sit on a read-only replica
# until the vrrp_script settles it on the Patroni leader; running CREATE
# EXTENSION before then fails "cannot execute CREATE EXTENSION in a read-only
# transaction". (0.P ratification transient T7.)
wait_rw() {
  local host="`$1"
  for i in `$(seq 1 40); do
    ro=`$(sudo -u postgres psql "host=`$host port=5432 dbname=postgres user=postgres `$TLS" -tA -c "SELECT pg_is_in_recovery()" 2>/dev/null || echo err)
    if [ "`$ro" = "f" ]; then return 0; fi
    sleep 3
  done
  echo "[citus-extension] ERROR: `$host VIP never settled on a read-write primary within 120s" >&2
  return 1
}

# 1. coordinator: database + extension
if [ "`$(pq_local postgres "SELECT 1 FROM pg_database WHERE datname='`$CITUS_DB'")" != "1" ]; then
  pq_local postgres "CREATE DATABASE `$CITUS_DB"
fi
pq_local "`$CITUS_DB" "CREATE EXTENSION IF NOT EXISTS citus"
echo "[citus-extension] coordinator: database `$CITUS_DB + citus extension ready"

# 2. each worker (via VIP, mTLS): database + extension
for w in '$w1Vip' '$w2Vip'; do
  wait_rw "`$w"
  if [ "`$(pq_remote "`$w" postgres "SELECT 1 FROM pg_database WHERE datname='`$CITUS_DB'")" != "1" ]; then
    pq_remote "`$w" postgres "CREATE DATABASE `$CITUS_DB"
  fi
  pq_remote "`$w" "`$CITUS_DB" "CREATE EXTENSION IF NOT EXISTS citus"
  echo "[citus-extension] worker `$w: database `$CITUS_DB + citus extension ready"
done

# 3. register coordinator host (by VIP) + add workers (by VIP), idempotent
pq_local "`$CITUS_DB" "SELECT citus_set_coordinator_host('coord.citus.nexus.lab', 5432)"
for w in worker1.citus.nexus.lab worker2.citus.nexus.lab; do
  if [ "`$(pq_local "`$CITUS_DB" "SELECT 1 FROM pg_dist_node WHERE nodename='`$w'")" != "1" ]; then
    pq_local "`$CITUS_DB" "SELECT citus_add_node('`$w', 5432)"
    echo "[citus-extension] added worker `$w to pg_dist_node"
  else
    echo "[citus-extension] worker `$w already in pg_dist_node (idempotent)"
  fi
done

# 4. citus_app role (auto-propagates to workers) + grant on the distributed db
pq_local "`$CITUS_DB" "DO \`$\`$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='citus_app') THEN CREATE ROLE citus_app LOGIN PASSWORD '`$APP_PWD'; ELSE ALTER ROLE citus_app WITH LOGIN PASSWORD '`$APP_PWD'; END IF; END \`$\`$;"
pq_local "`$CITUS_DB" "GRANT ALL ON DATABASE `$CITUS_DB TO citus_app"
pq_local "`$CITUS_DB" "GRANT ALL ON SCHEMA public TO citus_app"

# 5. verify: coordinator + 2 active workers in pg_dist_node
ACTIVE=`$(pq_local "`$CITUS_DB" "SELECT count(*) FROM pg_dist_node WHERE isactive AND noderole='primary'")
WORKERS=`$(pq_local "`$CITUS_DB" "SELECT count(*) FROM pg_dist_node WHERE isactive AND noderole='primary' AND groupid <> 0")
echo "[citus-extension] pg_dist_node: `$ACTIVE active primary nodes (`$WORKERS workers)"
if [ "`$WORKERS" -lt 2 ]; then
  echo "[citus-extension] ERROR: expected >=2 active workers, got `$WORKERS" >&2
  pq_local "`$CITUS_DB" "SELECT nodeid,groupid,nodename,nodeport,isactive,noderole FROM pg_dist_node ORDER BY groupid" >&2
  exit 1
fi
echo "CITUS_WIRED_OK"
"@
      $wireLf  = $wire -replace "`r`n", "`n"
      $wireOut = $wireLf | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $wireOut.Trim()
      if ($LASTEXITCODE -ne 0 -or $wireOut -notmatch 'CITUS_WIRED_OK') {
        throw "[citus-extension] Citus wiring failed (rc=$LASTEXITCODE)"
      }
      Write-Host "[citus-extension] Citus distributed cluster wired: coordinator + 2 workers active in pg_dist_node, citus_app role created."
    PWSH
  }
}
