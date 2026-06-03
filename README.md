# nexus-infra-citus

**Phase 0.P of NexusPlatform** — a Citus-sharded PostgreSQL cluster with full
Patroni HA: the **PostgreSQL-native horizontal-sharding** tier (the PG sibling
of `nexus-infra-vitess`'s MySQL sharding).

- **Engine:** PostgreSQL 17 + the **Citus 13.x** extension
  (`shared_preload_libraries='citus'`). A **coordinator** holds the distributed
  catalog (`pg_dist_*`) and routes/aggregates queries; **worker** node-groups
  hold the shards of every distributed table.
- **HA:** every node-group is a 2-node **Patroni** cluster (1 leader + 1
  streaming replica) over a shared 3-node **etcd** DCS, each fronted by a
  **keepalived VRRP VIP** that floats to the current leader (its `vrrp_script`
  probes the local Patroni REST `/leader`). The coordinator registers each
  worker in `pg_dist_node` **by its VIP**, so a worker failover leaves the Citus
  metadata valid with no rewrite.
- **Topology** (ADR-0042): 9 VMs + 3 VIPs, tier `08-citus` —
  - 3× **etcd** 3.5 (Patroni DCS quorum) — `.202`–`.204`
  - 2× **coordinator** Patroni pair (group `coord`, VIP `.211`) — `.205`/`.206`
  - 2× **worker-1** Patroni pair (group `worker1`, VIP `.212`) — `.207`/`.208`
  - 2× **worker-2** Patroni pair (group `worker2`, VIP `.213`) — `.209`/`.210`
- **Security:** full **Vault-PKI mTLS** on the PG wire (client↔coordinator,
  coordinator↔worker, Patroni↔PG, streaming replication), the etcd peer+client
  channels, and the Patroni REST API (`citus-server` PKI role; VIP IP-SANs baked
  into each PG node's cert). Per-host Vault Agent renders leaf certs + PG creds.
- **Networking:** VMnet11 service net (mgmt + the client-facing coordinator
  endpoint `:5432` + Patroni REST `:8008`); VMnet10 backplane (PG streaming
  replication, coordinator↔worker, Patroni↔etcd, VRRP).

## Status

**In ratification** (Phase 0.P). Per-engine Packer templates + per-cluster
Terraform state per `feedback_per_cluster_state_per_engine_template`.

## Layout

```
packer/citus-etcd-node/                   # etcd 3.5 Patroni DCS template (DISABLED unit)
packer/citus-pg-node/                     # PG17 + Citus + Patroni + keepalived template (DISABLED units)
terraform/envs/citus/                     # per-cluster state: 9 VMs + bring-up overlays
terraform/modules/vm/                     # VMware clone module (shared)
scripts/citus.ps1                         # operator wrapper (apply/destroy/cycle/smoke/plan/validate)
scripts/smoke-0.P.ps1                     # exit gate (Patroni HA + mTLS + sharding proof + worker-failover)
scripts/build-templates.ps1               # build the 2 templates
docs/handbook.md                          # from-zero replay guide (§0 prereqs … §3 runbooks)
```

## Quick start

```pwsh
# prereqs (other repo): foundation dhcp pins + VIP DNS + vault PKI/creds/sidecars
pwsh -File ..\nexus-infra-vmware\scripts\foundation.ps1 apply
pwsh -File ..\nexus-infra-vmware\scripts\security.ps1   apply
# this repo:
pwsh -File scripts\build-templates.ps1     # ~30-45 min (2 templates)
pwsh -File scripts\citus.ps1 apply         # -parallelism=3 first apply
pwsh -File scripts\citus.ps1 smoke
```

See [docs/handbook.md](docs/handbook.md) for the exact from-zero replay,
selective-ops examples, and the cold-rebuild canon.
