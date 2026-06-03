/*
 * citus-etcd-node -- etcd DCS node template (Phase 0.P).
 * Per-engine refactor per memory/feedback_per_cluster_state_per_engine_template.md.
 * 3 clones: citus-etcd-1/2/3 (.202/.203/.204). The etcd raft quorum is the
 * Patroni DISTRIBUTED CONFIGURATION STORE (DCS) shared by all three Citus
 * Patroni scopes (/citus/coord, /citus/worker1, /citus/worker2): it holds each
 * scope's leader lock, member states, and dynamic config -- Patroni on every
 * PG node reads/writes it to elect leaders + drive failover. (Citus itself
 * does NOT use etcd; distribution metadata lives in the coordinator's pg_dist_*
 * catalog. etcd is purely the Patroni DCS.)
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as siblings)
 *   - Default RAM: 1 GB at bake time (etcd is memory-light); steady-state 1 GB
 *     per vms.yaml is set at clone time by terraform vmrun-resize.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service);
 *     ethernet1 = VMnet10 (etcd peer raft 2380 + client API 2379 cross-mesh).
 *
 * Build-time vs clone-time vs first-boot:
 *   - Build-time (this template): single NAT NIC for apt fetch. etcd binary
 *     downloaded from upstream GitHub releases (apt's etcd is too old --
 *     stuck at 3.4.x; we need 3.5+ for the gRPC v3 API Patroni's etcd3 DCS
 *     plugin uses). Binaries at /usr/local/bin/etcd + etcdctl + etcdutl. The
 *     canonical unit (nexus-etcd.service) is delivered DISABLED.
 *   - Clone-time (terraform/modules/vm): writes ethernet0 + ethernet1 MAC.
 *   - First-boot (citus-node-firstboot.service): standard MAC OUI pattern;
 *     role=etcd cluster=citus for .202/.203/.204; writes /etc/nexus-citus/
 *     node-identity.env.
 *   - Cluster bring-up (terraform/envs/citus/role-overlay-*.tf):
 *     nftables-backplane -> citus-vault-agents (etcd nodes get a Vault Agent)
 *     -> citus-tls -> etcd-bootstrap (renders etcd.conf with the 3-member
 *     initial-cluster string + mTLS peer/client certs + starts nexus-etcd
 *     across all 3 -> waits for leader -> `etcdctl auth enable`). Patroni on
 *     the PG nodes then uses this etcd as its DCS.
 *
 * Build:   cd packer/citus-etcd-node; packer init .; packer build .
 * See:     docs/handbook.md
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware = {
      version = ">= 1.0.11"
      source  = "github.com/hashicorp/vmware"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

source "vmware-iso" "citus-etcd-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "citus-etcd-node template (Phase 0.P) -- built by Packer; etcd ${var.etcd_version} (upstream GitHub release; static binary at /usr/local/bin/etcd) as the Citus topology server"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "citus-etcd-node"
  sources = ["source.vmware-iso.citus-etcd-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/citus_firstboot",
      "ansible/roles/citus_etcd",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "citus_etcd_version=${var.etcd_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- citus-etcd-node post-install checks ---'",
      "test -x /usr/local/bin/etcd",
      "test -x /usr/local/bin/etcdctl",
      "test -x /usr/local/bin/etcdutl",
      "test -x /usr/local/sbin/nexus-etcdctl",
      "/usr/local/bin/etcd --version | head -1",
      "/usr/local/bin/etcdctl version | head -1",
      "systemctl cat nexus-etcd.service > /dev/null",
      "systemctl cat citus-node-firstboot.service > /dev/null",
      "systemctl is-enabled citus-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "sudo test -d /var/lib/nexus-etcd",
      "id etcd",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
