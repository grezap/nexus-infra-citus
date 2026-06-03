/*
 * citus-etcd-node -- Packer template variables (Phase 0.P)
 */

variable "vm_name" {
  type        = string
  default     = "citus-etcd-node"
  description = "VM display name and output .vmx basename."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/citus-etcd-node"
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

variable "etcd_version" {
  type        = string
  default     = "3.5.16"
  description = "etcd version downloaded from upstream GitHub releases (https://github.com/etcd-io/etcd/releases/download/v{{ version }}/etcd-v{{ version }}-linux-amd64.tar.gz). Default 3.5.16 (current stable patch on the 3.5 LTS line). Citus's etcd2topo plugin uses the v3 gRPC API (stable since 3.5.0); pinning to 3.5.16 gets the latest security fixes within the LTS series."
}

variable "cpus" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type        = number
  default     = 1024
  description = "Build-time RAM (MB). Default 1 GB (etcd is light); steady-state 2 GB per vms.yaml is set at clone time."
}

variable "disk_gb" {
  type        = number
  default     = 20
  description = "Disk size in GB. Default 20 GB; etcd state + snapshots are small."
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
