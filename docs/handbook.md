# nexus-infra-citus — Operator Handbook (Phase 0.P)

Citus-sharded PostgreSQL with full Patroni HA (ADR-0042). 9 VMs + 3 VRRP VIPs,
tier `08-citus`:

| Role | Hosts | VMnet11 | VIP |
|---|---|---|---|
| etcd DCS | citus-etcd-1/2/3 | .202/.203/.204 | — |
| coordinator Patroni pair | citus-coord-1/2 | .205/.206 | .211 (coord.citus.nexus.lab) |
| worker-1 Patroni pair | citus-worker1-1/2 | .207/.208 | .212 (worker1.citus.nexus.lab) |
| worker-2 Patroni pair | citus-worker2-1/2 | .209/.210 | .213 (worker2.citus.nexus.lab) |

This handbook is a from-absolute-zero replay guide. No external knowledge is
required to rebuild the tier.

---

## §0 Prerequisites — what must already exist

### §0.1 Build-host tooling

- Windows 11 build host, PowerShell 7+ (`pwsh`).
- `packer` ≥ 1.11, `terraform` ≥ 1.9, `vmrun.exe` at the non-`(x86)` path
  `C:\Program Files\VMware\VMware Workstation\vmrun.exe`.
- `ssh` / `scp` (OpenSSH) on PATH; key `~/.ssh/nexus_gateway_ed25519` works for
  `nexusadmin@<vmnet11-ip>` (or password `nexusadmin` fallback).
- Debian 13.5 netinst ISO at `H:\VMS\ISO\debian-13.5.0-amd64-netinst.iso`.

### §0.2 Foundation tier alive (6-VM base) + Vault unsealed

`vmrun list` must show the 6-VM foundation base running:
`nexus-gateway` + `dc-nexus` + `vault-1/2/3` + `vault-transit`. Confirm Vault is
unsealed:

```pwsh
ssh -i ~/.ssh/nexus_gateway_ed25519 nexusadmin@192.168.70.121 `
  "export VAULT_ADDR=https://127.0.0.1:8200; export VAULT_SKIP_VERIFY=1; vault status | grep -i sealed"
# Sealed   false
```

If a host reboot sealed Vault, recover via
`nexus-infra-vmware/scripts/recover-vault-ha.ps1` before proceeding.

### §0.3 Cross-repo state this tier reads (nexus-infra-vmware)

Two `nexus-infra-vmware` envs must be applied FIRST (they write gateway pins +
Vault PKI/creds/sidecars this repo consumes):

**foundation env** — writes:
- 9 dnsmasq dhcp-host pins for the citus MACs `:D7`–`:DF` → `.202`–`.210`
  (`role-overlay-gateway-citus-reservations.tf`, default
  `enable_citus_dhcp_reservations=true`).
- 3 VIP DNS host-records `coord/worker1/worker2.citus.nexus.lab` → `.211/.212/.213`
  (`role-overlay-gateway-citus-dns.tf`).

```pwsh
pwsh -File ..\nexus-infra-vmware\scripts\foundation.ps1 apply
```

**security env** — writes:
- PKI role `citus-server` (`pki_int/issue/citus-server`, server+client EKU, 90d,
  allowed_domains = 9 hosts ×3 forms + 3 VIP DNS names + localhost, allow_ip_sans).
- 4 KV sticky-seeds at `nexus/citus/{superuser,replication,patroni-restapi,citus-app}-password`.
- 9 narrow Vault policies + 9 AppRoles + the 9 sidecars at
  `$HOME\.nexus\vault-agent-citus-<host>.json` (this repo's vault-agents overlay
  reads these — ERROR if absent).
- The CA bundle at `$HOME\.nexus\vault-ca-bundle.crt`.

```pwsh
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1 apply
```

### §0.4 Templates built (see §1.1)

`H:\VMS\NexusPlatform\_templates\citus-etcd-node\citus-etcd-node.vmx` and
`...\citus-pg-node\citus-pg-node.vmx` must exist.

---

## §1 Phase walkthrough — from absolute zero

### §1.1 Build the Packer templates

```pwsh
# both (pg first — riskiest: PG 17 + Citus apt + Patroni venv + keepalived), ~30-45 min:
pwsh -File scripts\build-templates.ps1
# or one at a time:
pwsh -File scripts\build-templates.ps1 -Only pg
pwsh -File scripts\build-templates.ps1 -Only etcd
```

- `citus-etcd-node`: etcd 3.5.x upstream static binary (the Patroni DCS),
  `nexus-etcd.service` DISABLED, `nexus-etcdctl` wrapper.
- `citus-pg-node`: PostgreSQL 17 (Debian trixie native) + Citus 14.x (Citus
  community apt repo) + Patroni 4.x (pip venv, etcd3 + psycopg2) + keepalived;
  Debian's auto `main` cluster dropped + `postgresql` units masked;
  `nexus-patroni.service` + `nexus-keepalived.service` DISABLED.

### §1.2 Cross-env operator order (HARD ordering)

```
nexus-infra-vmware  foundation apply   (pins + VIP DNS)
nexus-infra-vmware  security   apply   (PKI role + KV creds + 9 AppRole sidecars)
nexus-infra-citus   citus.ps1 apply    (this repo: clones + bring-up graph)
```

The citus apply ERRORs early ("creds file … missing") if the security sidecars
aren't present — that's the cross-env guard, not a bug.

### §1.3 Apply

```pwsh
# FIRST 9-VM apply: -parallelism=3 to avoid the vmrun power-on storm (lesson N10).
pwsh -File scripts\citus.ps1 apply
# overlay-only re-applies once the VMs exist can use full parallelism:
pwsh -File scripts\citus.ps1 apply -Parallelism 10
```

Apply graph (within `terraform/envs/citus/`):

```
module.{etcd_*,coord_*,worker*_*}        9 clones (parallel, capped at -parallelism)
  -> citus_nftables_backplane            per-cluster ruleset on all 9
  -> citus_vault_agent  (x9)             Vault Agent per host (AppRole auth)
  -> citus_tls          (x9)             leaf cert (+ pg: 4 KV creds, 0600 key); per-group VIP SAN
  -> citus_etcd_bootstrap                3-member etcd, client-cert-auth, leader
  -> citus_patroni_bootstrap             3 scopes: 1 leader + 1 replica each; shared_preload=citus
  -> citus_keepalived   (x6)             per-group VIP follows the Patroni leader
  -> citus_extension                     CREATE EXTENSION citus + add workers by VIP + citus_app
  -> citus_distribute                    reference + distributed(32 shards) + colocated + seed + proof
```

### §1.4 Verify the exit gate

```pwsh
pwsh -File scripts\citus.ps1 smoke
# or: pwsh -File scripts\smoke-0.P.ps1
# skip the destructive worker-failover test: pwsh -File scripts\smoke-0.P.ps1 -SkipFailoverTest
```

Useful manual probes (run from a coordinator node):

```bash
# Patroni topology per scope
sudo /usr/local/sbin/nexus-patronictl list citus-coord
sudo /usr/local/sbin/nexus-patronictl list citus-worker1
# Citus cluster membership
sudo -u postgres psql -h /var/run/nexus-citus -U postgres -d citus -c "SELECT * FROM pg_dist_node ORDER BY groupid"
# shard placement (sharding proof)
sudo -u postgres psql -h /var/run/nexus-citus -U postgres -d citus -c "SELECT nodename, count(*) FROM citus_shards WHERE table_name='events'::regclass GROUP BY nodename"
# cross-shard aggregate
sudo -u postgres psql -h /var/run/nexus-citus -U postgres -d citus -c "SELECT count(*) FROM events"
```

### §1.5 Iterating (selective ops)

```pwsh
# stand up only the VMs + base plane (no Citus wiring) — useful to inspect
# Patroni/PG on a clone before the extension/distribute overlays:
pwsh -File scripts\citus.ps1 apply -Vars "enable_citus_extension=false,enable_citus_distribute=false"
# iterate on just the distribute overlay (rest already up):
cd terraform\envs\citus; terraform apply -auto-approve -replace="null_resource.citus_distribute[0]"
# bring up only one Patroni group's nodes:
pwsh -File scripts\citus.ps1 apply -Vars "enable_worker2_1=false,enable_worker2_2=false"
```

### §1.6 Tear down

```pwsh
pwsh -File scripts\citus.ps1 destroy
```

---

## §2 Phase status

| Sub-phase | State |
|---|---|
| Templates (etcd + pg) | _to be filled at ratification_ |
| Live ratification (smoke ALL GREEN) | _to be filled_ |
| Cold-rebuild proof | _to be filled_ |

---

## §3 Operator runbooks

### §3.1 Cold-rebuild canon

```pwsh
# 1. (optional) rebuild templates to bake any firstboot/role fixes:
pwsh -File scripts\build-templates.ps1
# 2. destroy:
pwsh -File scripts\citus.ps1 destroy
# 3. cross-env regen (idempotent; re-asserts pins + regenerates AppRole secret-ids):
pwsh -File ..\nexus-infra-vmware\scripts\foundation.ps1 apply
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1   apply
# 4. from-zero apply (vmrun-storm-safe):
pwsh -File scripts\citus.ps1 apply
# 5. smoke ALL GREEN:
pwsh -File scripts\citus.ps1 smoke
```

### §3.x Transient table — the 0.P ratification gauntlet

| # | Symptom | Diagnosis | Fix (in source) |
|---|---|---|---|
| T1 | `citus-pg-node` build fails: `No package matching 'postgresql-17-citus-13.0' is available` | (a) The Citus codename probe used `HEAD` + checked `status==200`, but packagecloud answers `dists/<cn>/Release` with a **302** to a signed S3 URL → probe saw 302, wrongly fell back to `bookworm`. (b) Even so, `13.0` is a bookworm-only version string; Debian **trixie**'s Citus repo publishes `postgresql-17-citus-{13.2,13.3,14.0,14.1}`. | Probe with `GET` + `follow_redirects: all` (final S3 GET = 200 → use the running codename `trixie`); bump `citus_version` default `13.0`→**`14.1`** (latest GA; avoid-EOL-optics, same principle as 0.O Percona 8.0→8.4). |
| T2 | `citus-pg-node` build fails at "Verify patroni + patronictl binaries": `patronictl --version` → `Error: No such option '--version'` (rc=2). | `patroni` supports `--version`; **`patronictl` does not** (Click CLI with no top-level `--version`). The verify loop ran `--version` on both. | Split the verify: `patroni --version` only; confirm `patronictl` via `ansible.builtin.stat` (`executable`). |
| T3 | `citus-pg-node` build fails at "Show installed versions": `debug` → `No first item, sequence was empty`. (ok=42 — all installs succeeded.) | The version-display did `... | map(attribute='stdout_lines') | map('first')`; **`keepalived --version` writes to STDERR**, so its `stdout_lines` is empty and `first` blows up. | `--version` only postgres + patroni (stdout); confirm keepalived via `stat` (its `--version` is checked combined-output in the Packer post-install); debug maps `stdout` not `stdout_lines\|first`. |
| T4 | `citus_patroni_bootstrap` never converges; `nexus-patroni` exits 1 in a restart loop → `PatroniException: '/var/run/nexus-citus' ... couldn't create the directory` / `PermissionError [Errno 13]`. | Patroni runs as **postgres** but `/run` (=/var/run) is root-owned **tmpfs**; postgres can't mkdir its `unix_socket_directories`. (memory: systemd RuntimeDirectory for /var/run paths.) | Add `RuntimeDirectory=nexus-citus` + `RuntimeDirectoryMode=0755` to `nexus-patroni.service` (systemd creates `/run/nexus-citus` owned by `postgres` each start, durable across reboots). For clones predating the fix, the patroni-bootstrap overlay drops the same as an idempotent `…/nexus-patroni.service.d/10-runtimedir.conf` + `reset-failed` to clear the start-limit. |
| T6 | Smoke §5/§9 fail: VIP REST `/leader` returns 000; after a worker failover the VIP is stranded on the **demoted replica** (queries to that worker break). | **Two faults.** (a) Smoke bug: `curl --cacert /etc/nexus-citus/tls/ca.pem` ran as `nexusadmin`, but `…/tls` is `0750 root:postgres` → can't traverse → `error setting certificate file` → 000. (b) Infra bug: `nopreempt` in the keepalived VRRP instance pinned the VIP to whoever was MASTER first, blocking the leader (priority 150 via the check weight) from taking it — so after a Patroni failover the VIP stayed on the old (now replica) node. | (a) `sudo curl` in the smoke VIP probes. (b) Remove `nopreempt` from the keepalived config so the leader preempts and the VIP follows leadership (bump `keepalived_v`→2). |
| T5 | Coordinator scope: leader runs, but the **replica stays `stopped`**; `pg_basebackup … FATAL: connection requires a valid client certificate` + `no pg_hba.conf entry for replication … no encryption`. | The replication `hostssl … clientcert=verify-ca` rule requires the replica to present a CA-signed **client cert** over SSL, but Patroni's `primary_conninfo` (replication/rewind) carried no `sslcert`/`sslkey`/`sslmode`, so it connected without a cert (even falling back to no-encryption). | Add `sslmode: verify-ca` + `sslrootcert`/`sslcert`/`sslkey` (the node's own leaf) to the `superuser` + `replication` + `rewind` blocks under `postgresql.authentication` in `patroni.yml`. Switch the bring-up `systemctl start`→`restart` so the re-rendered conninfo is applied. |

### §3.y Recovery notes

- **Vault sealed after host reboot** → `recover-vault-ha.ps1`, then re-run the
  citus vault-agents overlay (`terraform apply -replace` the affected
  `null_resource.citus_vault_agent[...]`).
- **A worker VIP not bound** → check `systemctl status nexus-keepalived` +
  `sudo /usr/local/sbin/nexus-patronictl list <scope>`; the VIP only binds on the
  current leader (the `vrrp_script` curls REST `/leader`).
- **Coordinator can't reach a worker** (`citus_add_node` errors) → confirm the
  worker VIP is bound + the worker's cert covers the VIP DNS name/IP (it does by
  construction) + `~postgres/.pgpass` holds the superuser password on the
  coordinator leader.
