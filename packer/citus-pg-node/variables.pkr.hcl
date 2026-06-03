/*
 * citus-pg-node -- Packer template variables (Phase 0.P)
 */

variable "vm_name" {
  type        = string
  default     = "citus-pg-node"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/citus-pg-node"
  description = "Absolute directory for the built template (.vmx + disks)."
}

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
}

variable "pg_major" {
  type        = number
  default     = 17
  description = "PostgreSQL major version. Debian 13 (trixie) ships PostgreSQL 17 natively; Citus 14.x supports PG 15-17."
}

variable "citus_version" {
  type        = string
  default     = "14.1"
  description = "Citus extension version (the Citus apt package is postgresql-<pg_major>-citus-<citus_version>, e.g. postgresql-17-citus-14.1). Citus 14.1 is the latest GA line supporting PG 17 (Debian trixie's Citus repo publishes 13.2/13.3/14.0/14.1 for PG 17; 13.0/13.1 are bookworm-only). Latest-GA chosen for the same avoid-EOL-optics principle as the 0.O Vitess Percona 8.0->8.4 switch."
}

variable "patroni_version" {
  type        = string
  default     = "4.0.5"
  description = "Patroni version installed into the /opt/patroni-venv pip venv (with the etcd3 DCS + psycopg2 extras). Patroni 4.x has first-class etcd3-over-TLS DCS support."
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB; matches steady-state per vms.yaml."
}

variable "disk_gb" {
  type        = number
  default     = 60
  description = "Disk size in GB. Default 60 GB (single disk; PGDATA + WAL + shard placements)."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "15s"
}

variable "ssh_timeout" {
  type    = string
  default = "30m"
}
