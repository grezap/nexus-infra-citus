# Changelog — nexus-infra-citus

All notable changes to the Citus-sharded PostgreSQL tier (NexusPlatform Phase
0.P). Format loosely follows Keep a Changelog; the repo is versioned to the
NexusPlatform phase cadence.

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
  Citus 13.x (Citus community apt repo) + Patroni 4.x (pip venv, etcd3 DCS +
  psycopg2) + keepalived. Debian's auto `main` cluster dropped + `postgresql`
  units masked (Patroni owns the lifecycle); `nexus-patroni.service` +
  `nexus-keepalived.service` delivered DISABLED (config-gated); stock
  `keepalived.service` masked; `nexus-patronictl` operator wrapper.

### Canon

- ADR-0042 (`nexus-platform-plan`) + `vms.yaml` `citus` cluster (9 VMs + 3 VIPs)
  + ADR index. MAC pool `:D7`–`:DF` / IPs `.202`–`.213` — pre-apply audit ALL
  CLEAR.
