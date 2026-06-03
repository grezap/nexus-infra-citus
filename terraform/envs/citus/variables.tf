# nexus-infra-citus / terraform / envs / citus / variables.tf
# Per-cluster Citus PG sharding + Patroni HA + etcd DCS state -- Phase 0.P.

# --- Shared paths -----------------------------------------------------------

variable "template_root" {
  type        = string
  default     = "H:\\VMS\\NexusPlatform\\_templates"
  description = "Root directory of Packer-built .vmx templates."
}

variable "vm_output_dir_root" {
  type        = string
  default     = "H:\\VMS\\NexusPlatform"
  description = "Root directory under which per-VM clone subdirs live (08-citus/<name>)."
}

variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}

variable "vnet_primary" {
  type        = string
  default     = "VMnet11"
  description = "Service network (mgmt + PG 5432 client coordinator endpoint + Patroni REST 8008 + etcd client 2379)."
}

variable "vnet_secondary" {
  type        = string
  default     = "VMnet10"
  description = "Cluster backplane -- streaming replication + coordinator<->worker + etcd raft 2380 + VRRP unicast."
}

# ─── etcd DCS per-VM toggles + MACs (.202-.204 / :D7-:D9) ──────────────────

variable "enable_etcd_1" {
  type    = bool
  default = true
}
variable "enable_etcd_2" {
  type    = bool
  default = true
}
variable "enable_etcd_3" {
  type    = bool
  default = true
}

variable "mac_etcd_1_primary" {
  type    = string
  default = "00:50:56:3F:00:D7"
}
variable "mac_etcd_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:D7"
}
variable "mac_etcd_2_primary" {
  type    = string
  default = "00:50:56:3F:00:D8"
}
variable "mac_etcd_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:D8"
}
variable "mac_etcd_3_primary" {
  type    = string
  default = "00:50:56:3F:00:D9"
}
variable "mac_etcd_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:D9"
}

# ─── coordinator Patroni pair (.205/.206 / :DA-:DB) ───────────────────────

variable "enable_coord_1" {
  type    = bool
  default = true
}
variable "enable_coord_2" {
  type    = bool
  default = true
}

variable "mac_coord_1_primary" {
  type    = string
  default = "00:50:56:3F:00:DA"
}
variable "mac_coord_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:DA"
}
variable "mac_coord_2_primary" {
  type    = string
  default = "00:50:56:3F:00:DB"
}
variable "mac_coord_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:DB"
}

# ─── worker-group-1 Patroni pair (.207/.208 / :DC-:DD) ────────────────────

variable "enable_worker1_1" {
  type    = bool
  default = true
}
variable "enable_worker1_2" {
  type    = bool
  default = true
}

variable "mac_worker1_1_primary" {
  type    = string
  default = "00:50:56:3F:00:DC"
}
variable "mac_worker1_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:DC"
}
variable "mac_worker1_2_primary" {
  type    = string
  default = "00:50:56:3F:00:DD"
}
variable "mac_worker1_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:DD"
}

# ─── worker-group-2 Patroni pair (.209/.210 / :DE-:DF) ────────────────────

variable "enable_worker2_1" {
  type    = bool
  default = true
}
variable "enable_worker2_2" {
  type    = bool
  default = true
}

variable "mac_worker2_1_primary" {
  type    = string
  default = "00:50:56:3F:00:DE"
}
variable "mac_worker2_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:DE"
}
variable "mac_worker2_2_primary" {
  type    = string
  default = "00:50:56:3F:00:DF"
}
variable "mac_worker2_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:DF"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────

variable "enable_nftables_backplane" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-citus-nftables-backplane.tf -- per-cluster ruleset (22 + 5432 + 8008 + 2379 + 2380 + VRRP + VMnet10 trust) pushed to all 9 citus-tier nodes."
}

variable "enable_citus_vault_agents" {
  type        = bool
  default     = true
  description = "Master gate for role-overlay-citus-vault-agents.tf (all 9 hosts -- etcd + pg each get their own Vault Agent)."
}

variable "enable_etcd_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_etcd_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_etcd_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_coord_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_coord_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_worker1_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_worker1_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_worker2_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_worker2_2_vault_agent" {
  type    = bool
  default = true
}

variable "enable_citus_tls" {
  type        = bool
  default     = true
  description = "role-overlay-citus-tls.tf -- render 3-file TLS split + per-role KV creds on all 9 nodes (pg nodes carry their group VIP in IP-SANs + the VIP DNS name in alt_names)."
}

variable "enable_etcd_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-citus-etcd-bootstrap.tf -- one-shot: render etcd.conf.yml on the 3 etcd nodes (client-cert-auth mTLS, no RBAC password), start nexus-etcd.service in parallel, wait for leader."
}

variable "enable_patroni_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-citus-patroni-bootstrap.tf -- one-shot: per scope (citus-coord / citus-worker1 / citus-worker2) render patroni.yml on the group's 2 nodes, start nexus-patroni.service in parallel, wait for 1 leader + 1 streaming replica + psql round-trip."
}

variable "enable_keepalived" {
  type        = bool
  default     = true
  description = "role-overlay-citus-keepalived.tf -- per group, render keepalived.conf on the 2 PG nodes; vrrp_script curls the local Patroni REST /leader (200 only on leader) so the VIP floats to the current leader. Unicast VRRP (VMware VMnet10/11 multicast doesn't traverse reliably)."
}

variable "enable_citus_extension" {
  type        = bool
  default     = true
  description = "role-overlay-citus-extension.tf -- one-shot on the coordinator leader: CREATE EXTENSION citus on coordinator + both workers, citus_set_coordinator_host(coord VIP), citus_add_node(worker VIPs), create the citus_app role + nexus distributed database."
}

variable "enable_citus_distribute" {
  type        = bool
  default     = true
  description = "role-overlay-citus-distribute.tf -- one-shot: create distributed + reference + colocated demo tables, seed rows, verify shards span both worker groups + a cross-shard aggregate routes through the coordinator."
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────

variable "citus_node_user" {
  type    = string
  default = "nexusadmin"
}

variable "citus_cluster_timeout_minutes" {
  type    = number
  default = 20
}

variable "vault_agent_version" {
  type    = string
  default = "1.18.5"
}

variable "vault_agent_citus_creds_dir" {
  type        = string
  default     = "$HOME/.nexus"
  description = "Directory on the build host holding the 9 vault-agent-citus-<host>.json AppRole sidecars."
}

variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}

variable "vault_pki_citus_role_name" {
  type    = string
  default = "citus-server"
}

# ─── Citus topology (scopes + VIPs + distributed DB) ──────────────────────

variable "citus_database" {
  type        = string
  default     = "citus"
  description = "The database in which the Citus extension + distributed/reference tables live. Created on every node post-Patroni-bootstrap by the citus-extension overlay."
}

variable "citus_coordinator_vip" {
  type        = string
  default     = "192.168.70.211"
  description = "Coordinator group VRRP VIP (client endpoint + citus_set_coordinator_host). DNS coord.citus.nexus.lab."
}

variable "citus_worker1_vip" {
  type        = string
  default     = "192.168.70.212"
  description = "Worker-group-1 VRRP VIP (registered in pg_dist_node). DNS worker1.citus.nexus.lab."
}

variable "citus_worker2_vip" {
  type        = string
  default     = "192.168.70.213"
  description = "Worker-group-2 VRRP VIP (registered in pg_dist_node). DNS worker2.citus.nexus.lab."
}
