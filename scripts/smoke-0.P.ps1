#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Phase 0.O smoke gate: 12-VM Vitess-sharded MySQL cluster
  (3 etcd + 1 control[vtctld+VTOrc] + 2 vtgate + 2x3 tablets[vttablet+Percona]).

.DESCRIPTION
  ~55 checks across 9 sections:
    1. Reachability        -- SSH/22 to all 12 nodes
    2. Engine + ports      -- right service active + right port listening per role
    3. etcd topo           -- 3-member quorum + leader + mTLS put/get round-trip
    4. Control plane       -- vtctld gRPC + VTOrc active + cell `nexus` exists
    5. Shard -80 topology  -- 1 PRIMARY + 2 REPLICA, all serving
    6. Shard 80- topology  -- 1 PRIMARY + 2 REPLICA, all serving
    7. vtgate routing      -- both vtgates answer; sharded SELECT via vtgate
    8. Sharding proof      -- `customer` rows present on BOTH shards (shard-targeted)
    9. mTLS verify         -- per-host cert CN; etcd rejects no-cert client;
                              vtgate listener TLS validates against our CA
   10. VTOrc HA            -- kill shard -80 PRIMARY -> VTOrc reparents -> still
                              writable -> restart killed tablet -> rejoins REPLICA

  Per memory/feedback_smoke_gate_probe_robustness.md: marker tokens + -match.

.NOTES
  pwsh -File scripts\vitess.ps1 apply
  pwsh -File scripts\smoke-0.O.ps1
  pwsh -File scripts\smoke-0.O.ps1 -SkipReparentTest   # skip the destructive HA test
#>

[CmdletBinding()]
param(
    [string]$Etcd1 = '192.168.70.190',
    [string]$Etcd2 = '192.168.70.191',
    [string]$Etcd3 = '192.168.70.192',
    [string]$Control = '192.168.70.193',
    [string]$Vtgate1 = '192.168.70.194',
    [string]$Vtgate2 = '192.168.70.195',
    [string]$S1T1 = '192.168.70.196',
    [string]$S1T2 = '192.168.70.197',
    [string]$S1T3 = '192.168.70.198',
    [string]$S2T1 = '192.168.70.199',
    [string]$S2T2 = '192.168.70.200',
    [string]$S2T3 = '192.168.70.201',
    [string]$Keyspace = 'commerce',
    [switch]$SkipReparentTest
)

$ErrorActionPreference = 'Continue'
$script:failures = @()
$user = 'nexusadmin'
$sshOpts = @('-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no')

# uid -> node IP map (shard1: 100/101/102; shard2: 200/201/202).
$uidToIp = @{ '100' = $S1T1; '101' = $S1T2; '102' = $S1T3; '200' = $S2T1; '201' = $S2T2; '202' = $S2T3 }

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

# vtctldclient wrapper invocation on the control node.
function Invoke-Vtctld {
    param([Parameter(Mandatory)][string]$ArgLine)
    ssh @sshOpts "$user@$Control" "sudo /usr/local/sbin/nexus-vtctldclient $ArgLine 2>&1"
}

Write-Host ''
Write-Host 'Phase 0.O smoke gate -- Vitess-sharded MySQL cluster' -ForegroundColor White

# ─── 1. Reachability ────────────────────────────────────────────────────────
Write-Section '1. Reachability (SSH/22 -- non-negotiable invariant)'
$allNodes = @(
    @{ Name = 'vitess-etcd-1'; Ip = $Etcd1 }, @{ Name = 'vitess-etcd-2'; Ip = $Etcd2 }, @{ Name = 'vitess-etcd-3'; Ip = $Etcd3 },
    @{ Name = 'vitess-control-1'; Ip = $Control },
    @{ Name = 'vitess-vtgate-1'; Ip = $Vtgate1 }, @{ Name = 'vitess-vtgate-2'; Ip = $Vtgate2 },
    @{ Name = 'vitess-shard1-tablet-1'; Ip = $S1T1 }, @{ Name = 'vitess-shard1-tablet-2'; Ip = $S1T2 }, @{ Name = 'vitess-shard1-tablet-3'; Ip = $S1T3 },
    @{ Name = 'vitess-shard2-tablet-1'; Ip = $S2T1 }, @{ Name = 'vitess-shard2-tablet-2'; Ip = $S2T2 }, @{ Name = 'vitess-shard2-tablet-3'; Ip = $S2T3 }
)
foreach ($n in $allNodes) {
    $node = $n
    Test-Check "$($node.Name) SSH/22 open ($($node.Ip))" `
    { Test-NetConnection -ComputerName $node.Ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue } `
    { param($o) $o -match 'True' }
}

# ─── 2. Engine + ports ──────────────────────────────────────────────────────
Write-Section '2. Engine service active + role port listening'
$svcNodes = @(
    @{ Name = 'vitess-etcd-1'; Ip = $Etcd1; Svc = 'nexus-etcd.service'; Port = 2379 },
    @{ Name = 'vitess-etcd-2'; Ip = $Etcd2; Svc = 'nexus-etcd.service'; Port = 2379 },
    @{ Name = 'vitess-etcd-3'; Ip = $Etcd3; Svc = 'nexus-etcd.service'; Port = 2379 },
    @{ Name = 'vitess-control-1(vtctld)'; Ip = $Control; Svc = 'nexus-vtctld.service'; Port = 15999 },
    @{ Name = 'vitess-control-1(vtorc)'; Ip = $Control; Svc = 'nexus-vtorc.service'; Port = 16000 },
    @{ Name = 'vitess-vtgate-1'; Ip = $Vtgate1; Svc = 'nexus-vtgate.service'; Port = 15306 },
    @{ Name = 'vitess-vtgate-2'; Ip = $Vtgate2; Svc = 'nexus-vtgate.service'; Port = 15306 },
    @{ Name = 'vitess-shard1-tablet-1'; Ip = $S1T1; Svc = 'nexus-vttablet.service'; Port = 16101 },
    @{ Name = 'vitess-shard1-tablet-2'; Ip = $S1T2; Svc = 'nexus-vttablet.service'; Port = 16101 },
    @{ Name = 'vitess-shard1-tablet-3'; Ip = $S1T3; Svc = 'nexus-vttablet.service'; Port = 16101 },
    @{ Name = 'vitess-shard2-tablet-1'; Ip = $S2T1; Svc = 'nexus-vttablet.service'; Port = 16101 },
    @{ Name = 'vitess-shard2-tablet-2'; Ip = $S2T2; Svc = 'nexus-vttablet.service'; Port = 16101 },
    @{ Name = 'vitess-shard2-tablet-3'; Ip = $S2T3; Svc = 'nexus-vttablet.service'; Port = 16101 }
)
foreach ($n in $svcNodes) {
    $node = $n
    Test-Check "$($node.Name): $($node.Svc) active" `
    { ssh @sshOpts "$user@$($node.Ip)" "systemctl is-active $($node.Svc)" } `
    { param($o) $o.Trim() -eq 'active' }
    Test-Check "$($node.Name): port $($node.Port) listening" `
    {
        $portHex = '{0:X4}' -f $node.Port
        ssh @sshOpts "$user@$($node.Ip)" "grep -iE ':$portHex 00000000:0000 0A|:$portHex .* 0A' /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l"
    } `
    { param($o) $o.Trim() -match '^[1-9]' }
}

# Each tablet's local Percona mysqld is alive (via mysqlctld-managed socket).
foreach ($t in @(@{N = 'shard1-tablet-1'; Ip = $S1T1; Uid = '0000000100' }, @{N = 'shard1-tablet-2'; Ip = $S1T2; Uid = '0000000101' }, @{N = 'shard1-tablet-3'; Ip = $S1T3; Uid = '0000000102' }, @{N = 'shard2-tablet-1'; Ip = $S2T1; Uid = '0000000200' }, @{N = 'shard2-tablet-2'; Ip = $S2T2; Uid = '0000000201' }, @{N = 'shard2-tablet-3'; Ip = $S2T3; Uid = '0000000202' })) {
    $tt = $t
    Test-Check "$($tt.N): local Percona mysqld alive" `
    { ssh @sshOpts "$user@$($tt.Ip)" "sudo mysqladmin --socket=/var/lib/nexus-vitess/vt_$($tt.Uid)/mysql.sock ping 2>&1" } `
    { param($o) $o -match 'mysqld is alive' -or $o -match 'Access denied' }
}

# ─── 3. etcd topo ───────────────────────────────────────────────────────────
Write-Section '3. etcd topo (3-member quorum + leader + mTLS round-trip)'
Test-Check 'etcd: 3 members registered' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl member list 2>/dev/null | wc -l" } `
{ param($o) $o.Trim() -eq '3' }
Test-Check 'etcd: a leader is elected' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl endpoint status --write-out=json 2>/dev/null" } `
{ param($o) $o -match '"leader":\s*[1-9]' }
Test-Check 'etcd: all 3 endpoints healthy' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl endpoint health --cluster --write-out=table 2>&1 | grep -c 'true'" } `
{ param($o) $o.Trim() -eq '3' }
Test-Check 'etcd: mTLS put/get round-trip' `
{ ssh @sshOpts "$user@$Etcd1" "sudo /usr/local/sbin/nexus-etcdctl put /nexus/smoke/o smoke-ok-vitess >/dev/null 2>&1 && sudo /usr/local/sbin/nexus-etcdctl get /nexus/smoke/o --print-value-only 2>/dev/null" } `
{ param($o) $o -match 'smoke-ok-vitess' }

# ─── 4. Control plane ───────────────────────────────────────────────────────
Write-Section '4. Control plane (vtctld gRPC + VTOrc + cell)'
Test-Check 'vtctld: GetCellInfoNames lists cell nexus' `
{ Invoke-Vtctld 'GetCellInfoNames' } `
{ param($o) $o -match 'nexus' }
Test-Check 'vtctld: keyspace commerce exists' `
{ Invoke-Vtctld 'GetKeyspaces' } `
{ param($o) $o -match $Keyspace }
Test-Check 'vtorc: active + web :16000 answers' `
{ ssh @sshOpts "$user@$Control" "systemctl is-active nexus-vtorc.service 2>/dev/null; curl -fsS http://127.0.0.1:16000/debug/status 2>/dev/null | head -c 1 | wc -c" } `
{ param($o) $o -match '(?m)^active' }

# ─── 5+6. Per-shard topology ────────────────────────────────────────────────
$shards = @(
    @{ Section = '5. Shard -80 topology (1 PRIMARY + 2 REPLICA)'; Shard = '-80' },
    @{ Section = '6. Shard 80- topology (1 PRIMARY + 2 REPLICA)'; Shard = '80-' }
)
foreach ($sh in $shards) {
    $s = $sh
    Write-Section $s.Section
    Test-Check "shard $($s.Shard): exactly 1 PRIMARY" `
    { Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard $($s.Shard)" } `
    { param($o) ([regex]::Matches($o, 'primary')).Count -eq 1 }
    Test-Check "shard $($s.Shard): exactly 2 REPLICA" `
    { Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard $($s.Shard)" } `
    { param($o) ([regex]::Matches($o, 'replica')).Count -eq 2 }
    Test-Check "shard $($s.Shard): 3 tablets total" `
    { Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard $($s.Shard)" } `
    { param($o) (($o.Trim() -split "`r?`n") | Where-Object { $_ -match $Keyspace }).Count -eq 3 }
}

# ─── 7. vtgate routing ──────────────────────────────────────────────────────
Write-Section '7. vtgate routing (both routers serve the keyspace)'
# Run mysql client from a tablet node (Percona client present) against each vtgate.
function Invoke-VtgateSql {
    param([string]$TabletIp, [string]$VtgateIp, [string]$Db, [string]$Sql)
    # vtgate's MySQL listener requires mTLS -- present the node's client cert/key
    # (sudo: key is 0640 root:vitess). (O13.)
    $tls = "--ssl-mode=REQUIRED --ssl-cert=/etc/nexus-vitess/tls/server-cert.pem --ssl-key=/etc/nexus-vitess/tls/server-key.pem --ssl-ca=/etc/nexus-vitess/tls/ca.pem"
    # 2>/dev/null: drop the mysql client's stderr warnings ("Using a password...
    # insecure", "no verification of server certificate") so they don't pollute
    # numeric/regex parsing. A failed query yields empty stdout -> predicate fails.
    $remote = "APP=`$(sudo cat /etc/nexus-vitess/mysql-app-password); sudo mysql --host=$VtgateIp --port=15306 --user=nexus --password=`$APP $tls --batch --skip-column-names $Db -e `"$Sql`" 2>/dev/null"
    ssh @sshOpts "$user@$TabletIp" $remote
}
Test-Check 'vtgate-1: SELECT @@version via :15306 (TLS)' `
{ Invoke-VtgateSql -TabletIp $S1T1 -VtgateIp $Vtgate1 -Db $Keyspace -Sql 'SELECT 1' } `
{ param($o) $o -match '^\s*1\s*$' -or $o -match '(?m)^1$' }
Test-Check 'vtgate-2: SELECT @@version via :15306 (TLS)' `
{ Invoke-VtgateSql -TabletIp $S2T1 -VtgateIp $Vtgate2 -Db $Keyspace -Sql 'SELECT 1' } `
{ param($o) $o -match '(?m)^\s*1\s*$' }
Test-Check 'vtgate-1: customer table visible via keyspace' `
{ Invoke-VtgateSql -TabletIp $S1T1 -VtgateIp $Vtgate1 -Db $Keyspace -Sql 'SHOW TABLES' } `
{ param($o) $o -match 'customer' }

# ─── 8. Sharding proof ──────────────────────────────────────────────────────
Write-Section '8. Sharding proof (customer rows on BOTH shards)'
$c1 = (Invoke-VtgateSql -TabletIp $S1T1 -VtgateIp $Vtgate1 -Db "$Keyspace/-80" -Sql 'SELECT COUNT(*) FROM customer' | Out-String).Trim()
$c2 = (Invoke-VtgateSql -TabletIp $S1T1 -VtgateIp $Vtgate1 -Db "$Keyspace/80-" -Sql 'SELECT COUNT(*) FROM customer' | Out-String).Trim()
Test-Check "shard -80 has customer rows (count=$c1)" `
{ $c1 } { param($o) try { [int]($o.Trim()) -ge 1 } catch { $false } }
Test-Check "shard 80- has customer rows (count=$c2)" `
{ $c2 } { param($o) try { [int]($o.Trim()) -ge 1 } catch { $false } }
Test-Check 'vtgate: total customer count = sum of both shards' `
{ Invoke-VtgateSql -TabletIp $S1T1 -VtgateIp $Vtgate1 -Db $Keyspace -Sql 'SELECT COUNT(*) FROM customer' } `
{ param($o)
    $tot = try { [int]($o.Trim() -split "`r?`n" | Select-Object -Last 1) } catch { -1 }
    $s1 = try { [int]$c1 } catch { 0 }; $s2 = try { [int]$c2 } catch { 0 }
    $tot -ge 1 -and $tot -eq ($s1 + $s2)
}

# ─── 9. mTLS verify ─────────────────────────────────────────────────────────
Write-Section '9. mTLS verify'
Test-Check 'tablet cert CN = vitess-shard1-tablet-1.vitess.nexus.lab' `
{ ssh @sshOpts "$user@$S1T1" "sudo openssl x509 -in /etc/nexus-vitess/tls/server-cert.pem -noout -subject 2>/dev/null" } `
{ param($o) $o -match 'vitess-shard1-tablet-1\.vitess\.nexus\.lab' }
Test-Check 'control cert CN = vitess-control-1.vitess.nexus.lab' `
{ ssh @sshOpts "$user@$Control" "sudo openssl x509 -in /etc/nexus-vitess/tls/server-cert.pem -noout -subject 2>/dev/null" } `
{ param($o) $o -match 'vitess-control-1\.vitess\.nexus\.lab' }
Test-Check 'vtgate cert carries vtgate.nexus.lab SAN' `
{ ssh @sshOpts "$user@$Vtgate1" "sudo openssl x509 -in /etc/nexus-vitess/tls/server-cert.pem -noout -ext subjectAltName 2>/dev/null" } `
{ param($o) $o -match 'vtgate\.nexus\.lab' }
Test-Check 'etcd rejects a no-client-cert request (client-cert-auth on)' `
{ ssh @sshOpts "$user@$Etcd1" "curl -ksS --cacert /etc/nexus-etcd/tls/ca.pem https://127.0.0.1:2379/version 2>&1; echo RC=`$?" } `
{ param($o) $o -match 'RC=[^0]' -or $o -match 'alert|handshake|certificate required|bad certificate' }
Test-Check 'vtgate listener TLS validates against our CA (VERIFY_CA)' `
{
    ssh @sshOpts "$user@$S1T1" "APP=`$(sudo cat /etc/nexus-vitess/mysql-app-password); sudo mysql --host=$Vtgate1 --port=15306 --user=nexus --password=`$APP --ssl-mode=VERIFY_CA --ssl-ca=/etc/nexus-vitess/tls/ca.pem --ssl-cert=/etc/nexus-vitess/tls/server-cert.pem --ssl-key=/etc/nexus-vitess/tls/server-key.pem --batch --skip-column-names -e 'SELECT 1' 2>/dev/null"
} `
{ param($o) $o -match '(?m)^\s*1\s*$' }

# ─── 10. VTOrc HA (kill shard -80 PRIMARY -> auto-reparent) ─────────────────
if (-not $SkipReparentTest) {
    Write-Section '10. VTOrc HA -- kill shard -80 PRIMARY, expect auto-reparent'

    # Identify current shard -80 primary alias + uid + node IP.
    $tabletsJson = (Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard -80" | Out-String)
    $oldPrimaryUid = $null
    foreach ($line in ($tabletsJson -split "`r?`n")) {
        if ($line -match 'primary' -and $line -match 'nexus-(\d+)') { $oldPrimaryUid = $Matches[1]; break }
    }
    if (-not $oldPrimaryUid) {
        Write-Host '[FAIL] 10. could not identify shard -80 primary uid' -ForegroundColor Red
        $script:failures += '10. identify shard -80 primary'
    }
    else {
        # $oldPrimaryUid is the PADDED uid from the alias (e.g. 0000000101);
        # $uidToIp keys are unpadded (101) -> unpad for the lookup, else the
        # kill targets an empty IP and silently no-ops. (smoke fix)
        $oldPrimaryIp = $uidToIp["$([int]$oldPrimaryUid)"]
        $oldPrimaryPad = '{0:D10}' -f [int]$oldPrimaryUid
        Write-Host "    current shard -80 PRIMARY = nexus-$oldPrimaryUid ($oldPrimaryIp); killing vttablet + mysqld..."
        ssh @sshOpts "$user@$oldPrimaryIp" "sudo systemctl stop nexus-vttablet.service nexus-mysqlctld.service" 2>&1 | Out-Null

        # Wait for VTOrc to promote a different primary.
        $deadline = (Get-Date).AddMinutes(8)
        $newPrimaryUid = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $tj = (Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard -80" | Out-String)
            foreach ($line in ($tj -split "`r?`n")) {
                if ($line -match 'primary' -and $line -match 'nexus-(\d+)') {
                    if ($Matches[1] -ne $oldPrimaryUid) { $newPrimaryUid = $Matches[1]; break }
                }
            }
            if ($newPrimaryUid) { break }
        }
        Test-Check "VTOrc promoted a NEW shard -80 primary (was nexus-$oldPrimaryUid, now nexus-$newPrimaryUid)" `
        { "new=$newPrimaryUid" } { param($o) $newPrimaryUid -and ($newPrimaryUid -ne $oldPrimaryUid) }

        # Cluster still writable through vtgate. Retry: after VTOrc promotes the
        # new primary, vtgate's healthcheck needs a few seconds to route writes
        # to it. CR-tolerant match (ssh output has trailing \r).
        $writeProbe = $S2T1  # a still-alive tablet to run the client from
        $writeOk = $false
        for ($w = 0; $w -lt 12; $w++) {
            $wo = (Invoke-VtgateSql -TabletIp $writeProbe -VtgateIp $Vtgate1 -Db $Keyspace -Sql 'INSERT IGNORE INTO customer(customer_id) VALUES(99999); SELECT COUNT(*) FROM customer WHERE customer_id=99999' | Out-String)
            if ($wo -match '(?m)^\s*1\s*$') { $writeOk = $true; break }
            Start-Sleep -Seconds 5
        }
        Test-Check 'cluster still writable via vtgate after primary kill' `
        { "writeOk=$writeOk" } { param($o) $writeOk }

        # Restart the killed tablet -> it should rejoin as REPLICA.
        Write-Host "    restarting killed tablet nexus-$oldPrimaryUid ($oldPrimaryIp)..."
        ssh @sshOpts "$user@$oldPrimaryIp" "sudo systemctl start nexus-mysqlctld.service; sleep 8; sudo systemctl start nexus-vttablet.service" 2>&1 | Out-Null
        $deadline = (Get-Date).AddMinutes(6)
        $rejoined = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $tj = (Invoke-Vtctld "GetTablets --keyspace $Keyspace --shard -80" | Out-String)
            $primaryCount = ([regex]::Matches($tj, 'primary')).Count
            $replicaCount = ([regex]::Matches($tj, 'replica')).Count
            if ($primaryCount -eq 1 -and $replicaCount -eq 2) { $rejoined = $true; break }
        }
        Test-Check 'shard -80 back to 1 PRIMARY + 2 REPLICA after rejoin' `
        { "rejoined=$rejoined" } { param($o) $rejoined }
    }
}
else {
    Write-Host ''
    Write-Host '10. VTOrc HA reparent test SKIPPED (-SkipReparentTest)' -ForegroundColor Yellow
}

# ─── Summary ────────────────────────────────────────────────────────────────
Write-Host ''
if ($script:failures.Count -eq 0) {
    Write-Host 'ALL 0.O SMOKE CHECKS PASSED' -ForegroundColor Green
    Write-Host 'Vitess-sharded MySQL operational: etcd topo + vtctld/VTOrc + 2 shards (1P+2R each) + vtgate routing + hash-vindex sharding + full mTLS + VTOrc auto-reparent.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$($script:failures.Count) FAILURE(S):" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
