# nexus-infra-vitess — Operator Handbook (Phase 0.O)

Vitess-sharded MySQL cluster: a horizontally-sharded relational database tier
(keyspace `commerce`, 2 shards, hash vindex) built on Percona Server 8.4 LTS
tablets fronted by Vitess v24.0.1 (vtgate / vttablet / vtctld / VTOrc), with an
etcd 3.5 topology service and **full Vault-PKI mTLS** on every gRPC channel, the
mysqld wire, and the vtgate MySQL listener. This is the relational **sharding**
axis of the NexusPlatform OLTP story (contrast 0.G.4 Patroni = PG HA-by-
replication; 0.N Mongo = document sharding; 0.O Vitess = MySQL sharding).

Canon: `nexus-platform-plan/MASTER-PLAN.md` (Phase 0.O) · `docs/adr/ADR-0041`
(topology) · `docs/infra/vms.yaml` (cluster `vitess`).

---

## §0 Prerequisites — what must already exist

### §0.1 Build-host tooling
- Windows 11 build host, PowerShell 7+ (`pwsh`).
- Terraform ≥ 1.9, Packer ≥ 1.11, VMware Workstation (vmrun at
  `C:/Program Files/VMware/VMware Workstation/vmrun.exe` — **non-(x86)**; see
  the cross-tier lesson `feedback_vmrun_path_moved_nonx86`).
- OpenSSH client (`ssh`/`scp`) on PATH.
- `H:\VMS\ISO\debian-13.5.0-amd64-netinst.iso`.

### §0.2 Foundation tier alive (6-VM base)
The always-on base must be up + healthy before anything here:

| VM | IP | Verify |
|----|----|--------|
| nexus-gateway | 192.168.70.1 | `ssh nexusadmin@192.168.70.1 "sudo systemctl is-active dnsmasq"` |
| dc-nexus | 192.168.70.10 | AD DS reachable |
| vault-1/2/3 | .121/.122/.123 | `vault status` → sealed=false, one `role=active` |
| vault-transit | .124 | `vault status` → sealed=false |

Host networking invariant: VMnet11 host adapter = `192.168.70.254`, VMnet10 =
`192.168.10.254` (Virtual Network Editor; see `feedback_vmnet_host_adapter_ip_reset`).
After any host reboot recover in order: **(1) VMnet adapters → .254 (admin) →
(2) `nexus-infra-vmware/scripts/recover-vault-ha.ps1` → (3) confirm vmrun path**.

### §0.3 Cross-repo state this tier reads
1. **dnsmasq dhcp-host reservations** for the 12 vitess MACs `:CB`–`:D6` →
   `.190`–`.201`. Written by `nexus-infra-vmware` foundation env overlay
   `role-overlay-gateway-vitess-reservations.tf`. Run **first**:
   ```pwsh
   pwsh -File nexus-infra-vmware\scripts\foundation.ps1 apply
   ```
   (Defaults are all `true` = steady state; a plain apply adds the vitess pins
   and preserves every other tier. `terraform plan` should read
   `1 to add, 0 to change, 0 to destroy`.)
2. **Vault PKI role + cluster creds + AppRoles**. Written by `nexus-infra-vmware`
   security env overlays (`role-overlay-vault-pki-vitess.tf`,
   `role-overlay-vault-vitess-cluster-creds-seed.tf`,
   `role-overlay-vault-agent-vitess-{policies,approles}.tf`). Run **second**:
   ```pwsh
   pwsh -File nexus-infra-vmware\scripts\security.ps1 apply
   ```
   This creates the `vitess-server` PKI role, sticky-seeds the 5 KV creds at
   `nexus/vitess/{mysql-root,mysql-app,mysql-allprivs,mysql-repl,vtorc-topo}-password`,
   writes the 12 narrow policies + 12 AppRoles, and drops the 12 per-host JSON
   sidecars at `~/.nexus/vault-agent-vitess-vitess-<host>.json`.
3. CA bundle `~/.nexus/vault-ca-bundle.crt` (from earlier foundation PKI work).

### §0.4 Templates built (see §1.1)
The 3 per-engine Packer templates must exist under `H:\VMS\NexusPlatform\_templates\`:
`vitess-etcd-node`, `vitess-gate-node`, `vitess-tablet-node`.

---

## §1 Phase walkthrough — from absolute zero

### §1.1 Build the Packer templates
Per-engine templates (one per role) per `feedback_per_cluster_state_per_engine_template`.
```pwsh
# all three (tablet first — riskiest: Percona 8.4 apt + Vitess tarball), ~30-45 min:
pwsh -File scripts\build-templates.ps1
# or one at a time:
pwsh -File scripts\build-templates.ps1 -Only tablet
pwsh -File scripts\build-templates.ps1 -Only gate
pwsh -File scripts\build-templates.ps1 -Only etcd
```
Each runs `packer build -force -var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso`.
Expected outputs: `H:\VMS\NexusPlatform\_templates\vitess-<role>-node\vitess-<role>-node.vmx`.

> **Build-time fixes baked into source** (an operator rebuilding hits neither;
> recorded for provenance, found at 0.O ratification 2026-06-02):
> - **B1** — the tablet role created the `vitess` user with supplementary group
>   `mysql` *before* Percona (which creates that group) was installed →
>   `Group mysql does not exist`. Fixed: create the user with its primary group
>   only, add it to `mysql` *after* the Percona install.
> - **B2** — Debian 13 / systemd 257 mounts `/tmp` as **tmpfs** (~½ build-RAM);
>   the full Vitess v24 tarball extracts to ~1.5 GB and overflowed it
>   (`No space left on device`). Fixed: download + extract the Vitess tarball
>   under `/var/tmp` (on the 60 GB root disk), not `/tmp`. Same family as the
>   0.G.4 vault-binary `/var/tmp` lesson. Applies to tablet + gate templates.

What each bakes (binaries + **DISABLED** systemd units; the TF overlays render
per-host config then enable + start):
- **vitess-etcd-node** — etcd/etcdctl/etcdutl 3.5.16 + `nexus-etcd.service` (disabled)
  + `/usr/local/sbin/nexus-etcdctl` wrapper.
- **vitess-tablet-node** — Percona Server 8.4 LTS (apt `ps-84-lts`; `mysql.service`
  masked — Vitess `mysqlctld` owns mysqld) + Vitess v24.0.1 `vttablet`/`mysqlctl`/
  `mysqlctld`/`vtctldclient` + `nexus-mysqlctld.service` + `nexus-vttablet.service`
  (disabled).
- **vitess-gate-node** — Vitess v24.0.1 `vtgate`/`vtctld`/`vtorc`/`vtctldclient`
  + `nexus-vtgate/vtctld/vtorc.service` (disabled). Serves BOTH the 2 vtgate
  routers AND the control node.

### §1.2 Cross-env operator order (HARD ordering)
1. `nexus-infra-vmware` **foundation apply** (writes the 12 dhcp pins) — §0.3.1.
2. `nexus-infra-vmware` **security apply** (PKI + creds + sidecars) — §0.3.2.
3. **this repo** vitess apply — §1.3.
The local apply reads the dhcp pins (so clones DHCP into `.190`–`.201`) and the
12 sidecars (so each Vault Agent can AppRole-login). Both MUST exist first.

### §1.3 Apply
```pwsh
# FIRST 12-VM apply: -parallelism=3 to avoid the vmrun power-on storm (lesson N10).
pwsh -File scripts\vitess.ps1 apply               # defaults to -parallelism=3
# overlay-only re-applies once the VMs exist can use full parallelism:
pwsh -File scripts\vitess.ps1 apply -Parallelism 10
```
Apply-graph (terraform orders by `depends_on`, not file name — Vitess bring-up is
NOT linear):
```
12x module.vm clone + power-on  (-parallelism=3 batches)
        │  firstboot per clone (NIC discovery, hostname, /etc/hosts, VMnet10, marker)
        ▼
role-overlay-vitess-nftables-backplane   (per-host ruleset; VMnet10 trust)
        ▼
role-overlay-vitess-vault-agents         (12x Vault Agent, AppRole login)
        ▼
role-overlay-vitess-tls                  (12x PKI leaf 3-file split + role KV creds)
        ▼
role-overlay-vitess-etcd-bootstrap       (3-member raft, full mTLS, leader+verify)
        ▼
role-overlay-vitess-gate :: vitess_vtctld   (EARLY: vtctld + AddCellInfo nexus
                                             + nexus-vtctldclient wrapper)
        ▼
role-overlay-vitess-tablets              (6x: init_db.sql+ssl.cnf+mysqlctld.env+
                                          vttablet.env; mysqld up; tablet registers)
        ▼
role-overlay-vitess-reparent             (per shard: SetKeyspaceDurabilityPolicy
                                          semi_sync + PlannedReparentShard → 1P+2R)
        ▼
role-overlay-vitess-gate :: vitess_vtgate (2x) + vitess_vtorc (1x)   (LATE)
        ▼
role-overlay-vitess-schema               (ApplySchema customer + ApplyVSchema hash
                                          vindex + seed via vtgate → BOTH shards)
```
Wall-clock estimate: ~25–40 min for a clean from-zero apply at `-parallelism=3`.

### §1.4 Verify the exit gate
```pwsh
pwsh -File scripts\vitess.ps1 smoke
# or: pwsh -File scripts\smoke-0.O.ps1
# skip the destructive VTOrc reparent test: pwsh -File scripts\smoke-0.O.ps1 -SkipReparentTest
```
~55 checks across 10 sections: reachability · engine+ports · etcd quorum ·
control plane (vtctld/VTOrc/cell) · per-shard 1P+2R · vtgate routing · sharding
proof (customer rows on BOTH shards) · mTLS verify · VTOrc auto-reparent-on-
primary-kill. Expected final line: `ALL 0.O SMOKE CHECKS PASSED`.

Manual spot-checks:
```pwsh
# topology
ssh nexusadmin@192.168.70.193 "sudo /usr/local/sbin/nexus-vtctldclient GetTablets --keyspace commerce"
# sharded query via vtgate (run from a tablet — it has the mysql client)
ssh nexusadmin@192.168.70.196 "APP=\$(sudo cat /etc/nexus-vitess/mysql-app-password); mysql -h 192.168.70.194 -P 15306 -u nexus -p\$APP --ssl-mode=REQUIRED commerce -e 'SELECT COUNT(*) FROM customer'"
# web UIs: vtctld http://192.168.70.193:15000 · VTOrc :16000 · vtgate :15001 · vttablet :15101
```

### §1.5 Iterating (selective ops)
Every overlay + every VM has an `enable_*` toggle (steady-state default `true`).
Pass the OPT-OUTS you want each apply (`-Vars` replaces the var set —
`feedback_terraform_partial_apply_destroys_resources`):
```pwsh
# stand up only the VMs + base plane (no tablets/reparent/gate/schema) — useful
# to verify Vitess flags against --help on a clone before the bring-up overlays:
pwsh -File scripts\vitess.ps1 apply -Vars "enable_vitess_tablets=false,enable_vitess_reparent=false,enable_vitess_gate=false,enable_vitess_schema=false"
# iterate on just the schema overlay (rest already up):
terraform -chdir=terraform\envs\vitess apply -auto-approve   # all defaults true
# bring up a single shard's tablets only:
pwsh -File scripts\vitess.ps1 apply -Vars "enable_vitess_shard2_tablet_1=false,enable_vitess_shard2_tablet_2=false,enable_vitess_shard2_tablet_3=false"
```

### §1.6 Tear down
```pwsh
pwsh -File scripts\vitess.ps1 destroy
```
Destroys the 12 clones + runs the per-overlay destroy provisioners (stop services,
remove rendered config). **Survives**: the gateway dhcp reservations, the Vault
PKI role + KV creds + AppRoles (cross-repo state in nexus-infra-vmware). A fresh
apply re-clones + re-renders from those.

---

## §2 Phase status

| Sub-phase | Scope | Closed | Smoke |
|-----------|-------|--------|-------|
| 0.O | Vitess-sharded MySQL (12 VMs, 2 shards, full mTLS, VTOrc) | **LIVE-RATIFIED 2026-06-03** | smoke-0.O.ps1 **71/71 GREEN** (incl. VTOrc reparent-on-kill + sharding proof + mTLS verify) |

---

## §3 Operator runbooks

### §3.1 Cold-rebuild canon
The proof that the tier rebuilds from absolute zero with zero hot state:
```pwsh
# 1. (optional) rebuild templates to bake any firstboot/role fixes:
pwsh -File scripts\build-templates.ps1
# 2. destroy:
pwsh -File scripts\vitess.ps1 destroy
# 3. cross-env regen (idempotent; re-asserts pins + regenerates AppRole secret-ids):
pwsh -File nexus-infra-vmware\scripts\foundation.ps1 apply
pwsh -File nexus-infra-vmware\scripts\security.ps1 apply
# 4. from-zero apply (vmrun-storm-safe):
pwsh -File scripts\vitess.ps1 apply        # -parallelism=3
# 5. smoke ALL GREEN:
pwsh -File scripts\vitess.ps1 smoke
```

### §3.x Transient table — the 0.O ratification gauntlet (2026-06-02)

All fixed in source; a cold rebuild hits none of them. Two host reboots occurred
during ratification (each needed the §0.2 recovery: VMnet adapters were already
.254, vault-HA re-recovered, 12 VMs powered back on + firstboot-ready).

**Build-time (Packer):**

| # | Symptom | Fix |
|---|---------|-----|
| B1 | tablet build fails `Group mysql does not exist` | vitess user added to `mysql` group AFTER Percona installs it (was before). |
| B2 | tablet build `No space left on device` unpacking Vitess tarball | Debian 13/systemd tmpfs `/tmp` (~½ RAM) too small for the ~1.5 GB extract → download+extract under `/var/tmp`. |
| B3 | tablet build exit 127, `mysqld: not found` | post-install spot-check called bare `mysqld` (in `/usr/sbin`, off PATH) → full path `/usr/sbin/mysqld`. |

**Apply-time:**

| # | Symptom | Diagnosis | Fix |
|---|---------|-----------|-----|
| T0 | vault reads `connection refused` :8200 | vault-transit boot race after host reboot | `recover-vault-ha.ps1` (×2 this session). [[vault-transit-boot-race-recovery]] |
| T1 | `terraform apply` Invalid-function-arg in schema locals | `one(keys(vtgate_nodes))` asserts ≤1 elem (2 vtgates) | use `values(...)[0]` for "first vtgate". |
| T2 | all 12 clones `configure-vm-nic.ps1 not recognized` | repo bootstrap copied `modules/vm` but not `scripts/configure-vm-nic.ps1` | copy the script into the repo. |
| T3 | etcd firstboot fails `chown: invalid group 'root:vitess'` | etcd template creates only the `etcd` group, but firstboot chowns node-identity to `vitess` | add `vitess` group to the etcd role. |
| T4 | etcd won't start, `server-cert.pem: no such file` | TLS overlay rendered all certs to `/etc/nexus-vitess/tls`, but etcd uses `/etc/nexus-etcd/tls` + runs as user `etcd` | role-aware TLS dirs (etcd→`/etc/nexus-etcd/tls` group etcd); destroy uses `lookup()` for back-compat. |
| T5 | vtctld gRPC never answers; wrapper `unknown flag: --grpc-ca` | `vtctldclient` connects with `--vtctld-grpc-*`, not the server-side `--grpc-*` | fix wrapper flags + add `--vtctld-grpc-server-name`. |
| T6 | reparent PRS `error reading server preface: EOF` | vtctld dials tablets' tabletmanager over mTLS but had no client cert | add `--tablet-manager-grpc-{ca,cert,key}` to vtctld. |
| T7 | tablets have **no vt_* users**; later `unsupported auth method: sha256_password` | `init_db.sql` first write hit `super_read_only` (errno 1290) → aborted; users never created | `init_db.sql` sets `super_read_only=OFF` first; users `IDENTIFIED WITH mysql_native_password` (+ `mysql_native_password=ON` in cnf). Wipe+re-init datadirs (live only; cold-rebuild starts empty). |
| T8 | tablet overlay hangs on mysqld-readiness | `mysqladmin ping` (no creds) returned "Access denied" once init_db set a root password; probe only matched "mysqld is alive" | accept "Access denied" as up (server responded). |
| T9 | seed to vtgate `Lost connection ... reading authorization packet` | vtgate MySQL listener requires mTLS (client cert); seed presented none | seed/smoke connect with `--ssl-cert/--ssl-key/--ssl-ca` (+ `sudo` for the 0640 key). |
| T10 | seed write times out 30s (errno 3024); replica IO `equal server ids`, Source_Host 127.0.0.1 | `--db-host 127.0.0.1` made Vitess advertise 127.0.0.1 as the tablet's MySQL host → replicas self-replicate; `semi_sync` durability blocked writes (semisync plugin not loaded) | drop `--db-host/--db-port` (Vitess advertises the VMnet10 host; replication flows); durability `none` (semi-sync + `plugin-load` is the 0.O.1 hardening). |
| T11 | smoke probe flakes (vtgate SELECT 1, VERIFY_CA, etcd put/get) | ssh output has trailing `\r` (strict `(?m)^1$` won't match `1\r`); mysql stderr warnings polluted parses; `$(date +%s)` ran on Windows PS | CR-tolerant predicates; `2>/dev/null` on mysql; static etcd value. |

### §3.1a — Cold-rebuild proof (2026-06-03)
PROVEN: rebuilt etcd template (bakes the `vitess` group, T3) → `vitess.ps1 destroy`
→ single `vitess.ps1 apply` (all defaults true, `-parallelism=3`) →
`Apply complete! Resources: 86 added, 0 changed, 0 destroyed` with **zero
transients** → `vitess.ps1 smoke` **71/71 GREEN** (incl. VTOrc reparent: killed
nexus-100, VTOrc promoted nexus-101). Confirms every B1–B3/T0–T12 fix lives in
source; the cross-repo prerequisites (dhcp pins, `vitess-server` PKI, 12 AppRole
sidecars) survived the destroy as designed.

### §3.1b — Live-ratification cold-state note
The live ratification ran the bring-up in two stages (base plane with
`-Vars enable_vitess_{tablets,reparent,gate,schema}=false`, then full) to isolate
the Vitess flag layer; a clean cold rebuild runs a single `apply` (all defaults
true).
