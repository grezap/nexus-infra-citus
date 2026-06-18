# Changelog — nexus-infra-citus

All notable changes to the Citus-sharded PostgreSQL tier (NexusPlatform Phase
0.P). Format loosely follows Keep a Changelog; the repo is versioned to the
NexusPlatform phase cadence.

## [Unreleased] — nexus-cli v0.7.3 CitusAdapter support (2026-06-18)

The Citus tier gained the cold-rebuild overlays the **`CitusAdapter`** (nexus-cli v0.7.3) needs — the
ADR-0011 Vault-KV operator-credential model, identical to every other password-auth adapter.

### Added
- **`role-overlay-citus-operator-user.tf`** (var `enable_citus_operator_user`) — one-shot on the
  coordinator leader: create the `nexus-cluster-admin` operator role (LOGIN CREATEROLE CREATEDB +
  pg_read/write_all_data + ALL on the `citus` DB + public; NOT superuser), password read on-node via the
  Vault Agent token from KV `nexus/citus/operator-password`. Citus auto-propagates the role to the workers;
  the overlay also appends `*:5432:*:nexus-cluster-admin:<pw>` to `~postgres/.pgpass` on **both** coordinator
  nodes so the coordinator dials the workers AS the operator → distributed queries run as the operator.
  Verifies a distributed `SELECT count(*) FROM events` via the coordinator VIP.

### Changed
- **`role-overlay-citus-patroni-bootstrap.tf` → v2** — added a top-level **`ctl:` block** to the rendered
  patroni.yml (cacert/certfile/keyfile = the node's own TLS) so `patronictl` presents a client cert for
  state-changing REST calls. Without it a graceful switchover 403s "client certificate required" (the REST
  `verify_client: optional` requires a client cert for unsafe endpoints) — caught live by the CitusAdapter
  failover verb, the same lesson as the 0.G.4 PatroniAdapter. patroni.yml stays `0640 postgres:postgres`
  (the daemon runs as postgres). ctl is client-only, so the change needs no restart.

## [v0.1.0] — Phase 0.P SEALED (2026-06-03)

**Live-ratified + cold-rebuild-proven** — `smoke-0.P.ps1` **69/69 GREEN** both
times (including the destructive worker-Patroni-failover test: kill the worker1
leader → Patroni promotes the standby → the keepalived VIP follows the new
leader → the cross-shard query keeps returning → the killed node rejoins as a
replica). 9 VMs + 3 VRRP VIPs on tier `08-citus`, PostgreSQL 17 + Citus 14.x,
full Vault-PKI mTLS.

### Ratification transients fixed in source (handbook §3.x T1–T6)

- **T1** — Citus apt: the codename probe followed the packagecloud 302 to use
  native `trixie`; `citus_version` `13.0`→**`14.1`** (latest GA; trixie publishes
  13.2/13.3/14.0/14.1 for PG 17).
- **T2** — `patronictl` has no `--version` flag → `stat` check instead.
- **T3** — `keepalived --version` writes to stderr → robust verify (no
  `stdout_lines|first` on an empty sequence).
- **T4** — Patroni (runs as `postgres`) couldn't `mkdir /run/nexus-citus` (tmpfs,
  root-owned) → `RuntimeDirectory=nexus-citus` in the unit (+ idempotent overlay
  drop-in + `reset-failed`).
- **T5** — replica `pg_basebackup` rejected (`clientcert=verify-ca`) → added
  `sslmode/sslcert/sslkey/sslrootcert` to the `superuser`/`replication`/`rewind`
  Patroni auth blocks; bring-up `start`→`restart`.
- **T6** — keepalived `nopreempt` stranded a VIP on a demoted replica → removed
  (VIP now follows the Patroni leader); smoke VIP curl needs `sudo` (CA behind a
  `0750 root:postgres` dir).

## [Unreleased] — Phase 0.P scaffold

### Added

- **Repo bootstrap** from the `nexus-infra-vitess` boilerplate: `_shared`
  Ansible roles (`nexus_identity` / `nexus_network` / `nexus_firewall` /
  `nexus_observability`), `terraform/modules/vm` (VMware clone module with the
  non-`(x86)` `vmrun_path` default), repo-root `ansible.cfg`, the
  `packer-validate` CI workflow (packer + terraform + ansible-lint + shell-lint
  + gitleaks), `LICENSE`, `.gitignore`.
- **`citus_firstboot`** shared role: NIC discovery by MAC OUI, hostname
  mapping, VMnet10 backplane `.link` MAC-match, `/etc/hosts` write, and the
  9-node Citus IP→role map (etcd `.202`–`.204`, coordinator `.205`/`.206`,
  worker1 `.207`/`.208`, worker2 `.209`/`.210`) writing
  `/etc/nexus-citus/node-identity.env` with a `NEXUS_GROUP` Patroni-scope field.
- **`citus-etcd-node`** Packer template: etcd 3.5.x upstream static binary as
  the Patroni DCS, `nexus-etcd.service` DISABLED, `nexus-etcdctl` operator
  wrapper.
- **`citus-pg-node`** Packer template: PostgreSQL 17 (Debian trixie native) +
  Citus 14.x (Citus community apt repo) + Patroni 4.x (pip venv, etcd3 DCS +
  psycopg2) + keepalived. Debian's auto `main` cluster dropped + `postgresql`
  units masked (Patroni owns the lifecycle); `nexus-patroni.service` +
  `nexus-keepalived.service` delivered DISABLED (config-gated); stock
  `keepalived.service` masked; `nexus-patronictl` operator wrapper.

### Canon

- ADR-0042 (`nexus-platform-plan`) + `vms.yaml` `citus` cluster (9 VMs + 3 VIPs)
  + ADR index. MAC pool `:D7`–`:DF` / IPs `.202`–`.213` — pre-apply audit ALL
  CLEAR.
