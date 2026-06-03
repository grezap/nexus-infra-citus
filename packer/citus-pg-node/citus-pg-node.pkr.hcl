/*
 * citus-pg-node -- PostgreSQL 17 + Citus + Patroni + keepalived node template
 * (Phase 0.P). Per-engine refactor per
 * memory/feedback_per_cluster_state_per_engine_template.md.
 *
 * 6 clones serve BOTH Citus node roles (the firstboot IP->role map + the
 * terraform patroni-bootstrap overlay decide which Patroni scope + Citus role
 * each clone takes):
 *   coordinator  citus-coord-1/2     (.205/.206)  Patroni scope `citus-coord`
 *   worker       citus-worker1-1/2   (.207/.208)  Patroni scope `citus-worker1`
 *   worker       citus-worker2-1/2   (.209/.210)  Patroni scope `citus-worker2`
 *
 * Software baked DISABLED (Terraform overlays render config + start):
 *   - PostgreSQL 17 (Debian trixie native) -- the auto-created `main` cluster
 *     is DROPPED + postgresql.service masked; Patroni owns the cluster
 *     lifecycle (initdb + start + failover).
 *   - Citus extension (postgresql-17-citus-NN from the Citus apt repo) --
 *     loaded via shared_preload_libraries='citus' set in patroni.yml.
 *   - Patroni (pip venv at /opt/patroni-venv; etcd3 DCS + psycopg2) +
 *     nexus-patroni.service (DISABLED; ConditionPathExists=/etc/patroni/patroni.yml).
 *   - keepalived + nexus-keepalived.service (DISABLED;
 *     ConditionPathExists=/etc/keepalived/keepalived.conf). Stock keepalived.service masked.
 *
 *   - OS: Debian 13 (same ISO + preseed pattern as citus-etcd-node)
 *   - Default RAM: 2 GB at bake time; steady-state 2 GB per vms.yaml.
 *   - Dual-NIC at clone time: ethernet0 = VMnet11 (service / client coordinator
 *     endpoint); ethernet1 = VMnet10 (PG streaming replication + coordinator<->
 *     worker + Patroni<->etcd + VRRP).
 *
 * Cluster bring-up (terraform/envs/citus/role-overlay-*.tf):
 *   nftables-backplane -> citus-vault-agents -> citus-tls -> etcd-bootstrap
 *   -> patroni-bootstrap (renders patroni.yml per scope + keepalived.conf per
 *   group; starts Patroni -> leader elected per scope; starts keepalived ->
 *   VIP binds to each scope's leader) -> citus-extension (CREATE EXTENSION
 *   citus + citus_set_coordinator_host + citus_add_node worker VIPs)
 *   -> citus-distribute (distributed + reference + colocated demo tables + seed).
 *
 * Build:   cd packer/citus-pg-node; packer init .; packer build .
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

source "vmware-iso" "citus-pg-node" {
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
    "annotation"           = "citus-pg-node template (Phase 0.P) -- built by Packer; PostgreSQL 17 + Citus ${var.citus_version} + Patroni ${var.patroni_version} (pip venv) + keepalived, all DISABLED at bake; Terraform overlays render config + start"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "citus-pg-node"
  sources = ["source.vmware-iso.citus-pg-node"]

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
      "sudo apt-get install -y -qq python3 python3-apt python3-venv python3-pip sudo ansible curl ca-certificates gnupg openssl jq unzip lsb-release"
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
      "ansible/roles/citus_pg",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "citus_pg_pg_major=${var.pg_major}",
      "--extra-vars", "citus_pg_citus_version=${var.citus_version}",
      "--extra-vars", "citus_pg_patroni_version=${var.patroni_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- citus-pg-node post-install checks ---'",
      "test -x /usr/lib/postgresql/${var.pg_major}/bin/postgres",
      "test -x /usr/lib/postgresql/${var.pg_major}/bin/initdb",
      "test -x /usr/lib/postgresql/${var.pg_major}/bin/pg_isready",
      "test -x /usr/lib/postgresql/${var.pg_major}/bin/pg_ctl",
      "test -x /opt/patroni-venv/bin/patroni",
      "test -x /opt/patroni-venv/bin/patronictl",
      "/opt/patroni-venv/bin/patroni --version",
      "test -x /usr/sbin/keepalived",
      "ls /usr/lib/postgresql/${var.pg_major}/lib/citus.so",
      "systemctl cat nexus-patroni.service > /dev/null",
      "systemctl cat nexus-keepalived.service > /dev/null",
      "systemctl cat citus-node-firstboot.service > /dev/null",
      "systemctl is-enabled citus-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "! systemctl is-enabled postgresql 2>/dev/null || (echo 'ERROR: postgresql.service must be masked/disabled' && false)",
      "! systemctl is-enabled keepalived 2>/dev/null || (echo 'ERROR: stock keepalived.service must be masked' && false)",
      "sudo test -d /var/lib/nexus-citus",
      "id postgres",
      "getent group citus",
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
