#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.P smoke gate: 9-VM Citus-sharded PostgreSQL cluster with full Patroni HA
  (3 etcd DCS + coordinator Patroni pair + 2 worker Patroni pairs + 3 VRRP VIPs).

.DESCRIPTION
  ~55 checks across 9 sections:
    1. Reachability      -- SSH/22 to all 9 nodes
    2. Engine + ports    -- right service active + right port listening per role
    3. etcd DCS          -- 3-member quorum + leader + client-cert-auth put/get
    4. Patroni HA        -- each scope (coord/worker1/worker2): 1 Leader + 1 Replica
    5. keepalived VIPs   -- each group VIP bound on the leader; REST /leader=200 on VIP
    6. Citus topology    -- pg_dist_node: coordinator + 2 active worker primaries
    7. Sharding proof    -- events shards span BOTH workers; cross-shard aggregate;
                            reference table replicated; colocated join
    8. mTLS verify       -- per-host cert CN; PG rejects a no-client-cert connection;
                            coordinator<->worker over verify-full TLS
    9. Worker failover   -- kill worker1 leader Patroni -> replica promoted -> VIP
                            moves -> cross-shard query still works -> restart rejoins

  Per memory/feedback_smoke_gate_probe_robustness.md: marker tokens + -match,
  CR-tolerant predicates, sudo stderr suppressed.

.NOTES
  pwsh -File scripts\citus.ps1 apply
  pwsh -File scripts\smoke-0.P.ps1
  pwsh -File scripts\smoke-0.P.ps1 -SkipFailoverTest   # skip the destructive HA test
#>

[CmdletBinding()]
param(
    [string]$Etcd1 = '192.168.70.202',
    [string]$Etcd2 = '192.168.70.203',
    [string]$Etcd3 = '192.168.70.204',
    [string]$Coord1 = '192.168.70.205',
    [string]$Coord2 = '192.168.70.206',
    [string]$Worker1a = '192.168.70.207',
    [string]$Worker1b = '192.168.70.208',
    [string]$Worker2a = '192.168.70.209',
    [string]$Worker2b = '192.168.70.210',
    [string]$CoordVip = '192.168.70.211',
    [string]$Worker1Vip = '192.168.70.212',
    [string]$Worker2Vip = '192.168.70.213',
    [string]$CitusDb = 'citus',
    [switch]$SkipFailoverTest
)

$ErrorActionPreference = 'Continue'
$script:failures = @()
$user = 'nexusadmin'
$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

$pgNodes = @{
    'citus-coord-1'   = $Coord1; 'citus-coord-2' = $Coord2
    'citus-worker1-1' = $Worker1a; 'citus-worker1-2' = $Worker1b
    'citus-worker2-1' = $Worker2a; 'citus-worker2-2' = $Worker2b
}
$scopeProbe = @{
    'citus-coord' = $Coord1; 'citus-worker1' = $Worker1a; 'citus-worker2' = $Worker2a
}

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Test-Check {
    param(
        [Parameter(Mandatory)][string]      $Label,
        [Parameter(Mandatory)][scriptblock] $Probe,
        [Parameter(Mandatory)][scriptblock] $Predicate
    )
    $out = & $Probe 2>&1 | Out-String
    $ok = & $Predicate $out
    if ($ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        Write-Host ($out.Trim() -split "`r?`n" | ForEach-Object { "       $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
        $script:failures += $Label
    }
}

# Return the leader member name for a Patroni scope (probes a known node).
function Get-PatroniLeader([string]$scope) {
    $probeIp = $scopeProbe[$scope]
    $listOut = (ssh @sshOpts "$user@$probeIp" "sudo /usr/local/sbin/nexus-patronictl list $scope --format json 2>/dev/null" 2>&1 | Out-String).Trim()
    if ($listOut -match '\[') {
        try {
            $leader = ($listOut | ConvertFrom-Json | Where-Object { $_.Role -eq 'Leader' } | Select-Object -First 1)
            if ($leader) { return $leader.Member }
        }
        catch { }
    }
    return $null
}

# Run a -tA psql query on the coordinator leader via the local unix socket as postgres.
function Invoke-CoordSql([string]$query) {
    $leader = Get-PatroniLeader 'citus-coord'
    if (-not $leader) { return '' }
    $leaderIp = $pgNodes[$leader]
    $q = $query -replace '"', '\"'
    return (ssh @sshOpts "$user@$leaderIp" "sudo -u postgres psql -h /var/run/nexus-citus -U postgres -d $CitusDb -tA -c `"$q`" 2>/dev/null" 2>&1 | Out-String).Trim()
}

Write-Host ''
Write-Host 'Phase 0.P smoke gate -- Citus-sharded PostgreSQL cluster (full Patroni HA)' -ForegroundColor White

# ─── 1. Reachability ────────────────────────────────────────────────────────
Write-Section '1. Reachability (SSH/22 -- non-negotiable invariant)'
$allNodes = @(
    @{ Name = 'citus-etcd-1'; Ip = $Etcd1 }, @{ Name = 'citus-etcd-2'; Ip = $Etcd2 }, @{ Name = 'citus-etcd-3'; Ip = $Etcd3 },
    @{ Name = 'citus-coord-1'; Ip = $Coord1 }, @{ Name = 'citus-coord-2'; Ip = $Coord2 },
    @{ Name = 'citus-worker1-1'; Ip = $Worker1a }, @{ Name = 'citus-worker1-2'; Ip = $Worker1b },
    @{ Name = 'citus-worker2-1'; Ip = $Worker2a }, @{ Name = 'citus-worker2-2'; Ip = $Worker2b }
)
foreach ($n in $allNodes) {
    Test-Check "SSH reachable: $($n.Name) ($($n.Ip))" `
    { ssh @sshOpts "$user@$($n.Ip)" "echo NEXUS_SSH_OK" } `
    { param($o) $o -match 'NEXUS_SSH_OK' }
}

# ─── 2. Engine + ports per role ──────────────────────────────────────────────
Write-Section '2. Engine + ports (service active + port listening per role)'
foreach ($e in @($Etcd1, $Etcd2, $Etcd3)) {
    Test-Check "etcd: nexus-etcd.service active ($e)" `
    { ssh @sshOpts "$user@$e" "systemctl is-active nexus-etcd.service" } `
    { param($o) $o -match '(?m)^active\s*$' }
    Test-Check "etcd: :2379 client API listening ($e)" `
    { ssh @sshOpts "$user@$e" "ss -ltn 'sport = :2379' | tail -n +2" } `
    { param($o) $o -match ':2379' }
}
foreach ($kv in $pgNodes.GetEnumerator()) {
    Test-Check "pg: nexus-patroni.service active ($($kv.Key))" `
    { ssh @sshOpts "$user@$($kv.Value)" "systemctl is-active nexus-patroni.service" } `
    { param($o) $o -match '(?m)^active\s*$' }
    Test-Check "pg: nexus-keepalived.service active ($($kv.Key))" `
    { ssh @sshOpts "$user@$($kv.Value)" "systemctl is-active nexus-keepalived.service" } `
    { param($o) $o -match '(?m)^active\s*$' }
    Test-Check "pg: :5432 PostgreSQL listening ($($kv.Key))" `
    { ssh @sshOpts "$user@$($kv.Value)" "ss -ltn 'sport = :5432' | tail -n +2" } `
    { param($o) $o -match ':5432' }
}

# ─── 3. etcd DCS quorum ──────────────────────────────────────────────────────
Write-Section '3. etcd DCS (3-member quorum + leader + cert-auth put/get)'
Test-Check 'etcd: cluster has 3 members' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl member list 2>/dev/null | wc -l" } `
{ param($o) $o -match '(?m)^\s*3\s*$' }
Test-Check 'etcd: a leader is elected (endpoint status)' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl endpoint status --write-out=json 2>/dev/null" } `
{ param($o) $o -match '"leader":\s*[1-9][0-9]*' }
Test-Check 'etcd: cert-auth put/get round-trip' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl put /nexus/citus/smoke v1 >/dev/null 2>&1 && sudo /usr/local/sbin/nexus-etcdctl get /nexus/citus/smoke --print-value-only 2>/dev/null" } `
{ param($o) $o -match '(?m)^v1\s*$' }

# ─── 4. Patroni HA per scope ─────────────────────────────────────────────────
Write-Section '4. Patroni HA per scope (1 Leader + 1 streaming Replica)'
foreach ($scope in @('citus-coord', 'citus-worker1', 'citus-worker2')) {
    $probeIp = $scopeProbe[$scope]
    Test-Check "patroni ${scope}: 1 Leader present" `
    { ssh @sshOpts "$user@$probeIp" "sudo /usr/local/sbin/nexus-patronictl list $scope --format json 2>/dev/null" } `
    { param($o) try { (($o | ConvertFrom-Json) | Where-Object { $_.Role -eq 'Leader' }).Count -eq 1 } catch { $false } }
    Test-Check "patroni ${scope}: >=1 Replica running/streaming" `
    { ssh @sshOpts "$user@$probeIp" "sudo /usr/local/sbin/nexus-patronictl list $scope --format json 2>/dev/null" } `
    { param($o) try { $c = $o | ConvertFrom-Json; (($c | Where-Object { $_.Role -eq 'Replica' -or $_.Role -eq 'Sync Standby' }).Count -ge 1) -and (($c | Where-Object { $_.State -eq 'running' -or $_.State -eq 'streaming' }).Count -ge 2) } catch { $false } }
}

# ─── 5. keepalived VIPs follow the leader ────────────────────────────────────
Write-Section '5. keepalived VIPs (bound on the group leader; REST /leader=200 on VIP)'
$groupVips = @(
    @{ Scope = 'citus-coord'; Vip = $CoordVip; Nodes = @($Coord1, $Coord2) },
    @{ Scope = 'citus-worker1'; Vip = $Worker1Vip; Nodes = @($Worker1a, $Worker1b) },
    @{ Scope = 'citus-worker2'; Vip = $Worker2Vip; Nodes = @($Worker2a, $Worker2b) }
)
foreach ($g in $groupVips) {
    Test-Check "VIP $($g.Vip) ($($g.Scope)) bound on exactly one node" `
    {
        $bound = 0
        foreach ($ip in $g.Nodes) {
            $o = (ssh @sshOpts "$user@$ip" "ip -4 addr show dev nic0 2>/dev/null" | Out-String)
            if ($o -match [regex]::Escape($g.Vip)) { $bound++ }
        }
        "bound_count=$bound"
    } `
    { param($o) $o -match 'bound_count=1' }
    Test-Check "VIP $($g.Vip) Patroni REST /leader returns 200 (leader holds VIP)" `
    {
        $leaderIp = $g.Nodes[0]
        ssh @sshOpts "$user@$leaderIp" "sudo curl -s -o /dev/null -w '%{http_code}' --cacert /etc/nexus-citus/tls/ca.pem https://$($g.Vip):8008/leader 2>/dev/null"
    } `
    { param($o) $o -match '200' }
}

# ─── 6. Citus topology ───────────────────────────────────────────────────────
Write-Section '6. Citus topology (pg_dist_node: coordinator + 2 active workers)'
Test-Check 'citus: extension present in distributed DB' `
{ Invoke-CoordSql "SELECT extversion FROM pg_extension WHERE extname='citus'" } `
{ param($o) $o -match '\d+\.\d+' }
Test-Check 'citus: 2 active worker primaries in pg_dist_node' `
{ Invoke-CoordSql "SELECT count(*) FROM pg_dist_node WHERE isactive AND noderole='primary' AND groupid<>0" } `
{ param($o) $o -match '(?m)^2\s*$' }
Test-Check 'citus: coordinator registered (groupid 0)' `
{ Invoke-CoordSql "SELECT count(*) FROM pg_dist_node WHERE groupid=0" } `
{ param($o) $o -match '(?m)^1\s*$' }
Test-Check 'citus: workers registered by their VIP names' `
{ Invoke-CoordSql "SELECT string_agg(nodename, ',' ORDER BY nodename) FROM pg_dist_node WHERE groupid<>0" } `
{ param($o) $o -match 'worker1\.citus\.nexus\.lab' -and $o -match 'worker2\.citus\.nexus\.lab' }

# ─── 7. Sharding proof ───────────────────────────────────────────────────────
Write-Section '7. Sharding proof (shards span both workers; cross-shard aggregate; reference)'
Test-Check 'sharding: events shards span 2 worker nodes' `
{ Invoke-CoordSql "SELECT count(DISTINCT nodename) FROM citus_shards WHERE table_name='events'::regclass" } `
{ param($o) $o -match '(?m)^2\s*$' }
Test-Check 'sharding: cross-shard aggregate count(*) >= 800' `
{ Invoke-CoordSql "SELECT count(*) FROM events" } `
{ param($o) ($o.Trim() -as [int]) -ge 800 }
Test-Check 'sharding: tenants is a reference table (replicated)' `
{ Invoke-CoordSql "SELECT partmethod FROM pg_dist_partition WHERE logicalrelid='tenants'::regclass" } `
{ param($o) $o -match '(?m)^n\s*$' }
Test-Check 'sharding: colocated join events<->event_tags executes' `
{ Invoke-CoordSql "SELECT count(*) FROM events e JOIN event_tags t USING (tenant_id, event_id)" } `
{ param($o) ($o.Trim() -as [int]) -ge 1 }
Test-Check 'sharding: events + event_tags are colocated' `
{ Invoke-CoordSql "SELECT count(DISTINCT colocationid) FROM pg_dist_partition WHERE logicalrelid IN ('events'::regclass,'event_tags'::regclass)" } `
{ param($o) $o -match '(?m)^1\s*$' }

# ─── 8. mTLS verify ──────────────────────────────────────────────────────────
Write-Section '8. mTLS verify (per-host cert CN; PG rejects no-client-cert; verify-full inter-node)'
foreach ($kv in $pgNodes.GetEnumerator()) {
    Test-Check "cert CN = $($kv.Key).citus.nexus.lab ($($kv.Key))" `
    { ssh @sshOpts "$user@$($kv.Value)" "sudo openssl x509 -in /etc/nexus-citus/tls/server-cert.pem -noout -subject 2>/dev/null" } `
    { param($o) $o -match "$($kv.Key)\.citus\.nexus\.lab" }
}
Test-Check 'mTLS: PG rejects a no-client-cert connection (clientcert=verify-ca enforced)' `
{ ssh @sshOpts "$user@$Coord1" "psql 'host=$CoordVip port=5432 dbname=$CitusDb user=postgres sslmode=require' -c 'SELECT 1' 2>&1 | head -3" } `
{ param($o) $o -match 'certificate' -or $o -match 'connection requires' -or $o -match 'no pg_hba' }
Test-Check 'mTLS: coordinator dials workers over TLS (node_conninfo verify-full)' `
{ Invoke-CoordSql "SHOW citus.node_conninfo" } `
{ param($o) $o -match 'verify-full' }

# ─── 9. Worker failover HA ───────────────────────────────────────────────────
if (-not $SkipFailoverTest) {
    Write-Section '9. Worker failover HA (kill worker1 leader -> replica promoted -> VIP moves -> queries continue)'
    $w1Leader = Get-PatroniLeader 'citus-worker1'
    if (-not $w1Leader) {
        Test-Check 'worker1 leader identifiable for failover test' { 'leader=none' } { param($o) $false }
    }
    else {
        $w1LeaderIp = $pgNodes[$w1Leader]
        Write-Host "    worker1 leader = $w1Leader ($w1LeaderIp); stopping its nexus-patroni to force failover..."
        ssh @sshOpts "$user@$w1LeaderIp" "sudo systemctl stop nexus-patroni.service" 2>&1 | Out-Null

        $deadline = (Get-Date).AddMinutes(4)
        $newLeader = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 8
            $l = Get-PatroniLeader 'citus-worker1'
            if ($l -and $l -ne $w1Leader) { $newLeader = $l; break }
        }
        Test-Check "worker1: new leader elected ($newLeader != $w1Leader)" `
        { "old=$w1Leader new=$newLeader" } { param($o) $newLeader -and $newLeader -ne $w1Leader }

        Test-Check 'worker1 VIP still answers REST /leader=200 after failover' `
        { ssh @sshOpts "$user@$($pgNodes[$newLeader])" "sudo curl -s -o /dev/null -w '%{http_code}' --cacert /etc/nexus-citus/tls/ca.pem https://$Worker1Vip`:8008/leader 2>/dev/null" } `
        { param($o) $o -match '200' }
        Test-Check 'cross-shard aggregate still works after worker1 failover' `
        { Invoke-CoordSql "SELECT count(*) FROM events" } `
        { param($o) ($o.Trim() -as [int]) -ge 800 }

        Write-Host "    restarting $w1Leader to rejoin as replica..."
        ssh @sshOpts "$user@$w1LeaderIp" "sudo systemctl start nexus-patroni.service" 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(5)
        $rejoined = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $listOut = (ssh @sshOpts "$user@$($pgNodes[$newLeader])" "sudo /usr/local/sbin/nexus-patronictl list citus-worker1 --format json 2>/dev/null" 2>&1 | Out-String).Trim()
            try {
                $c = $listOut | ConvertFrom-Json
                $running = ($c | Where-Object { $_.State -eq 'running' -or $_.State -eq 'streaming' }).Count
                if ($running -ge 2) { $rejoined = $true; break }
            }
            catch { }
        }
        Test-Check 'worker1: back to 2 running members after rejoin' `
        { "rejoined=$rejoined" } { param($o) $rejoined }
    }
}
else {
    Write-Host ''
    Write-Host '9. Worker failover HA test SKIPPED (-SkipFailoverTest)' -ForegroundColor Yellow
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.P SMOKE CHECKS PASSED' -ForegroundColor Green
    Write-Host 'Citus-sharded PostgreSQL operational: etcd DCS + 3 Patroni groups (1L+1R each) + keepalived VIPs following leaders + coordinator + 2 workers in pg_dist_node + distributed/reference/colocated sharding + full mTLS + worker Patroni failover.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
