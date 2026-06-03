/*
 * role-overlay-citus-distribute.tf -- Phase 0.P
 *
 * One-shot: create the demo distribution schema on the coordinator and prove
 * the sharding works. Runs on the coordinator leader in the distributed
 * database (var.citus_database):
 *
 *   - `tenants`     : reference table (create_reference_table) -- replicated to
 *                     every worker + the coordinator; joinable with no reshuffle.
 *   - `events`      : distributed table (create_distributed_table by tenant_id,
 *                     32 shards) -- hash-partitioned across the 2 worker groups.
 *   - `event_tags`  : distributed table colocated with `events` on tenant_id --
 *                     so tenant-key joins are worker-local (no repartition).
 *
 * Seeds reference + distributed rows, then PROVES:
 *   1. events shards land on BOTH worker groups (count(distinct nodename) == 2).
 *   2. a cross-shard aggregate (SELECT count(*) FROM events) is routed/merged
 *      by the coordinator and returns the full seeded count.
 *   3. a colocated join (events JOIN event_tags USING (tenant_id, event_id))
 *      executes.
 *
 * Idempotent: tables created IF NOT EXISTS; create_*_table skipped if already
 * distributed; seed uses ON CONFLICT.
 *
 * Selective ops: var.enable_citus_distribute. Pre-req: citus_extension wired.
 */

resource "null_resource" "citus_distribute" {
  count = var.enable_citus_distribute ? 1 : 0

  triggers = {
    extension_id       = length(null_resource.citus_extension) > 0 ? null_resource.citus_extension[0].id : "disabled"
    citus_db           = var.citus_database
    citus_distribute_v = "1" # v1 (0.P) = reference(tenants) + distributed(events,32 shards) + colocated(event_tags) + sharding proof.
    coord_probe_ip     = "192.168.70.205"
  }

  depends_on = [null_resource.citus_extension]

  provisioner "local-exec" {
    when        = create
    interpreter = ["pwsh", "-NoProfile", "-Command"]
    command     = <<-PWSH
      $sshUser    = '${var.citus_node_user}'
      $sshOpts    = @('-o','ConnectTimeout=10','-o','BatchMode=yes','-o','StrictHostKeyChecking=no')
      $coordProbe = '192.168.70.205'
      $citusDb    = '${var.citus_database}'
      $timeout    = ${var.citus_cluster_timeout_minutes}

      # Find coordinator leader.
      $coordHosts = @{ 'citus-coord-1' = '192.168.70.205'; 'citus-coord-2' = '192.168.70.206' }
      $leaderHost = $null
      $deadline = (Get-Date).AddMinutes($timeout)
      while ((Get-Date) -lt $deadline -and -not $leaderHost) {
        $listOut = (ssh @sshOpts "$sshUser@$coordProbe" "sudo /usr/local/sbin/nexus-patronictl list --format json 2>/dev/null" 2>&1 | Out-String).Trim()
        if ($listOut -match '\[') {
          try { $leader = ($listOut | ConvertFrom-Json | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1); if ($leader) { $leaderHost = $leader.Member } } catch { }
        }
        if (-not $leaderHost) { Start-Sleep -Seconds 5 }
      }
      if (-not $leaderHost) { throw "[citus-distribute] could not find coordinator leader within $timeout min" }
      $leaderIp = $coordHosts[$leaderHost]
      Write-Host "[citus-distribute] coordinator leader = $leaderHost ($leaderIp)"

      $sql = @"
set -euo pipefail
SOCK=/var/run/nexus-citus
CITUS_DB='$citusDb'
pq() { sudo -u postgres psql -h "`$SOCK" -U postgres -d "`$CITUS_DB" -v ON_ERROR_STOP=1 -tA -c "`$1"; }

# Reference table (replicated to all nodes).
pq "CREATE TABLE IF NOT EXISTS tenants (tenant_id int PRIMARY KEY, name text NOT NULL)"
if [ "`$(pq "SELECT 1 FROM pg_dist_partition WHERE logicalrelid='tenants'::regclass")" != "1" ]; then
  pq "SELECT create_reference_table('tenants')"
fi

# Distributed table (hash on tenant_id, 32 shards across worker groups).
pq "SET citus.shard_count = 32; CREATE TABLE IF NOT EXISTS events (event_id bigint, tenant_id int NOT NULL, payload text, created_at timestamptz DEFAULT now(), PRIMARY KEY (tenant_id, event_id))"
if [ "`$(pq "SELECT 1 FROM pg_dist_partition WHERE logicalrelid='events'::regclass")" != "1" ]; then
  pq "SELECT create_distributed_table('events', 'tenant_id')"
fi

# Colocated distributed table.
pq "CREATE TABLE IF NOT EXISTS event_tags (event_id bigint, tenant_id int NOT NULL, tag text NOT NULL, PRIMARY KEY (tenant_id, event_id, tag))"
if [ "`$(pq "SELECT 1 FROM pg_dist_partition WHERE logicalrelid='event_tags'::regclass")" != "1" ]; then
  pq "SELECT create_distributed_table('event_tags', 'tenant_id', colocate_with => 'events')"
fi

# Seed reference + distributed rows (idempotent).
pq "INSERT INTO tenants (tenant_id, name) SELECT g, 'tenant-'||g FROM generate_series(1,8) g ON CONFLICT (tenant_id) DO NOTHING"
pq "INSERT INTO events (event_id, tenant_id, payload) SELECT g, (g % 8) + 1, 'evt-'||g FROM generate_series(1,800) g ON CONFLICT (tenant_id, event_id) DO NOTHING"
pq "INSERT INTO event_tags (event_id, tenant_id, tag) SELECT g, (g % 8) + 1, 'tag-'||(g % 5) FROM generate_series(1,800) g ON CONFLICT (tenant_id, event_id, tag) DO NOTHING"

# PROOF 1: events shards span BOTH worker groups.
NODES=`$(pq "SELECT count(DISTINCT nodename) FROM citus_shards WHERE table_name='events'::regclass")
echo "[citus-distribute] events shards spread across `$NODES worker node(s)"
if [ "`$NODES" -lt 2 ]; then
  echo "[citus-distribute] ERROR: events shards did not span 2 worker groups (got `$NODES)" >&2
  pq "SELECT nodename, count(*) AS shards FROM citus_shards WHERE table_name='events'::regclass GROUP BY nodename" >&2
  exit 1
fi

# PROOF 2: cross-shard aggregate routed/merged by the coordinator.
TOTAL=`$(pq "SELECT count(*) FROM events")
echo "[citus-distribute] cross-shard aggregate SELECT count(*) FROM events = `$TOTAL"
if [ "`$TOTAL" -lt 800 ]; then
  echo "[citus-distribute] ERROR: expected >=800 events, got `$TOTAL" >&2
  exit 1
fi

# PROOF 3: colocated join executes.
JOINED=`$(pq "SELECT count(*) FROM events e JOIN event_tags t USING (tenant_id, event_id)")
echo "[citus-distribute] colocated join events<->event_tags rows = `$JOINED"

# Shard distribution summary.
echo "[citus-distribute] shard placement summary:"
pq "SELECT nodename, count(*) AS shard_count FROM citus_shards WHERE table_name='events'::regclass GROUP BY nodename ORDER BY nodename"
echo "CITUS_DISTRIBUTE_OK"
"@
      $sqlLf  = $sql -replace "`r`n", "`n"
      $sqlOut = $sqlLf | ssh @sshOpts "$sshUser@$leaderIp" "tr -d '\r' | bash -s" 2>&1 | Out-String
      Write-Host $sqlOut.Trim()
      if ($LASTEXITCODE -ne 0 -or $sqlOut -notmatch 'CITUS_DISTRIBUTE_OK') {
        throw "[citus-distribute] distribution + seed + proof failed (rc=$LASTEXITCODE)"
      }
      Write-Host "[citus-distribute] sharding proven: events shards span both worker groups; cross-shard aggregate + colocated join OK."
    PWSH
  }
}
