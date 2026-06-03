# nexus-infra-citus / terraform / envs / citus / outputs.tf

output "citus_topology" {
  description = "Citus tier topology summary (Phase 0.P, ADR-0042)."
  value = {
    etcd_dcs = {
      "citus-etcd-1" = "192.168.70.202"
      "citus-etcd-2" = "192.168.70.203"
      "citus-etcd-3" = "192.168.70.204"
    }
    coordinator_group = {
      scope = "citus-coord"
      nodes = { "citus-coord-1" = "192.168.70.205", "citus-coord-2" = "192.168.70.206" }
      vip   = var.citus_coordinator_vip
      dns   = "coord.citus.nexus.lab"
    }
    worker_group_1 = {
      scope = "citus-worker1"
      nodes = { "citus-worker1-1" = "192.168.70.207", "citus-worker1-2" = "192.168.70.208" }
      vip   = var.citus_worker1_vip
      dns   = "worker1.citus.nexus.lab"
    }
    worker_group_2 = {
      scope = "citus-worker2"
      nodes = { "citus-worker2-1" = "192.168.70.209", "citus-worker2-2" = "192.168.70.210" }
      vip   = var.citus_worker2_vip
      dns   = "worker2.citus.nexus.lab"
    }
  }
}

output "client_endpoint" {
  description = "Client-facing coordinator endpoint (the VIP, floats to the coord Patroni leader). Connect distributed-DB clients here."
  value       = "postgresql://citus_app@coord.citus.nexus.lab:5432/${var.citus_database} (sslmode=verify-full, client cert required)"
}

output "etcd_client_endpoints" {
  description = "etcd DCS client endpoints (Patroni dials these; client-cert-auth mTLS)."
  value       = local.citus_etcd_client_endpoints
}

output "distributed_database" {
  description = "The database holding the Citus extension + distributed/reference tables."
  value       = var.citus_database
}
