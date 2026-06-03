# nexus-infra-citus / terraform / envs / citus / main.tf
#
# Per-cluster Terraform state for the Citus-sharded PostgreSQL HA stack
# (Phase 0.P, ADR-0042): 9 VMs + 3 VRRP VIPs.
#   - 3 etcd DCS nodes (citus-etcd-1/2/3) at .202-.204
#   - coordinator Patroni pair (citus-coord-1/2) at .205/.206, VIP .211
#   - worker-group-1 Patroni pair (citus-worker1-1/2) at .207/.208, VIP .212
#   - worker-group-2 Patroni pair (citus-worker2-1/2) at .209/.210, VIP .213
#
# Every PG node-group is its own 2-node Patroni cluster (1 leader + 1 streaming
# replica) over the shared 3-node etcd DCS, fronted by a keepalived VRRP VIP
# whose vrrp_script probes the local Patroni REST /leader so the VIP floats to
# the current leader. The coordinator registers each worker in pg_dist_node BY
# ITS VIP (so a worker failover needs no metadata rewrite). Full Vault-PKI mTLS
# on the PG wire + etcd + Patroni REST.
#
# Cross-env prerequisites:
#   1. nexus-infra-vmware foundation env: gateway dhcp-host pins for the 9
#      citus-tier MACs (.202-.210) + the 3 VIP DNS host-records.
#   2. nexus-infra-vmware security env: PKI role citus-server + 9 AppRoles +
#      4 KV sticky-seeds + 9 sidecars at $HOME\.nexus\vault-agent-citus-<host>.json.
#   3. Packer templates built:
#        H:\VMS\NexusPlatform\_templates\citus-etcd-node\citus-etcd-node.vmx
#        H:\VMS\NexusPlatform\_templates\citus-pg-node\citus-pg-node.vmx
#
# Apply order within this env:
#   module.etcd_* + module.coord_* + module.worker*_* (9 parallel clones)
#   -> null_resource.citus_nftables_backplane
#   -> null_resource.citus_vault_agent (for_each, 9 hosts)
#   -> null_resource.citus_tls (for_each, 9 hosts; pg nodes carry their group's
#      VIP in cert IP-SANs + the VIP DNS name in alt_names)
#   -> null_resource.citus_etcd_bootstrap (one-shot: render etcd.conf.yml on the
#      3 etcd nodes + start nexus-etcd in parallel + wait leader; client-cert-auth)
#   -> null_resource.citus_patroni_bootstrap (one-shot: per scope render
#      patroni.yml on the group's 2 nodes + start nexus-patroni in parallel +
#      wait 1 leader + 1 replica + psql round-trip)
#   -> null_resource.citus_keepalived (for_each, 6 pg nodes: render keepalived.conf
#      per group; vrrp_script curls local Patroni REST /leader; VIP follows leader)
#   -> null_resource.citus_extension (one-shot on the coordinator leader:
#      CREATE EXTENSION citus on coord+workers + citus_set_coordinator_host +
#      citus_add_node worker VIPs + create citus_app role)
#   -> null_resource.citus_distribute (one-shot: distributed + reference +
#      colocated demo tables + seed + verify shards span both worker groups)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── etcd DCS module.vm blocks (3 raft quorum members) ────────────────────

module "etcd_1" {
  source = "../../modules/vm"
  count  = var.enable_etcd_1 ? 1 : 0

  vm_name           = "citus-etcd-1"
  template_vmx_path = "${var.template_root}/citus-etcd-node/citus-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-etcd-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_1_secondary
}

module "etcd_2" {
  source = "../../modules/vm"
  count  = var.enable_etcd_2 ? 1 : 0

  vm_name           = "citus-etcd-2"
  template_vmx_path = "${var.template_root}/citus-etcd-node/citus-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-etcd-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_2_secondary
}

module "etcd_3" {
  source = "../../modules/vm"
  count  = var.enable_etcd_3 ? 1 : 0

  vm_name           = "citus-etcd-3"
  template_vmx_path = "${var.template_root}/citus-etcd-node/citus-etcd-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-etcd-3"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_etcd_3_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_etcd_3_secondary
}

# ─── coordinator Patroni pair module.vm blocks ────────────────────────────

module "coord_1" {
  source = "../../modules/vm"
  count  = var.enable_coord_1 ? 1 : 0

  vm_name           = "citus-coord-1"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-coord-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_coord_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_coord_1_secondary
}

module "coord_2" {
  source = "../../modules/vm"
  count  = var.enable_coord_2 ? 1 : 0

  vm_name           = "citus-coord-2"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-coord-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_coord_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_coord_2_secondary
}

# ─── worker-group-1 Patroni pair module.vm blocks ─────────────────────────

module "worker1_1" {
  source = "../../modules/vm"
  count  = var.enable_worker1_1 ? 1 : 0

  vm_name           = "citus-worker1-1"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-worker1-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_worker1_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_worker1_1_secondary
}

module "worker1_2" {
  source = "../../modules/vm"
  count  = var.enable_worker1_2 ? 1 : 0

  vm_name           = "citus-worker1-2"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-worker1-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_worker1_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_worker1_2_secondary
}

# ─── worker-group-2 Patroni pair module.vm blocks ─────────────────────────

module "worker2_1" {
  source = "../../modules/vm"
  count  = var.enable_worker2_1 ? 1 : 0

  vm_name           = "citus-worker2-1"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-worker2-1"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_worker2_1_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_worker2_1_secondary
}

module "worker2_2" {
  source = "../../modules/vm"
  count  = var.enable_worker2_2 ? 1 : 0

  vm_name           = "citus-worker2-2"
  template_vmx_path = "${var.template_root}/citus-pg-node/citus-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-citus/citus-worker2-2"
  vmrun_path        = var.vmrun_path

  vnet        = var.vnet_primary
  mac_address = var.mac_worker2_2_primary

  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_worker2_2_secondary
}
