output "control_plane_ip" {
  description = "External LAN IP address of Kubernetes control plane node"
  value       = module.control_plane.ip
}

output "control_plane_internal_ip" {
  description = "Internal KVM IP address of Kubernetes control plane node"
  value       = module.control_plane.internal_ip
}

output "control_plane_ssh" {
  description = "Ready-to-run SSH command for control plane"
  value       = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${module.control_plane.ip}"
}

output "worker_ips" {
  description = "External LAN IP addresses of Kubernetes worker nodes"
  value = {
    for k, v in module.workers : k => v.ip
  }
}

output "worker_internal_ips" {
  description = "Internal KVM IP addresses of Kubernetes worker nodes"
  value = {
    for k, v in module.workers : k => v.internal_ip
  }
}

output "worker_ssh_commands" {
  description = "Ready-to-run SSH commands for worker nodes"
  value = {
    for k, v in module.workers : k => "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${v.ip}"
  }
}

output "cluster_summary" {
  description = "Summary of all provisioned nodes, roles, IPs, and connection commands"
  value = merge(
    {
      (var.control_plane.name) = {
        role         = "control-plane"
        external_ip  = module.control_plane.ip
        internal_ip  = module.control_plane.internal_ip
        external_mac = module.control_plane.mac_address
        internal_mac = module.control_plane.internal_mac_address
        ssh_command  = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${module.control_plane.ip}"
      }
    },
    {
      for k, v in module.workers : k => {
        role         = "worker"
        external_ip  = v.ip
        internal_ip  = v.internal_ip
        external_mac = v.mac_address
        internal_mac = v.internal_mac_address
        ssh_command  = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${v.ip}"
      }
    }
  )
}
