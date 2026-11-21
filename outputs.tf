output "control_plane_ip" {
  description = "IP address of Kubernetes control plane node"
  value       = module.control_plane.ip
}

output "control_plane_ssh" {
  description = "Ready-to-run SSH command for control plane"
  value       = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${module.control_plane.ip}"
}

output "worker_ips" {
  description = "IP addresses of Kubernetes worker nodes"
  value = {
    for k, v in module.workers : k => v.ip
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
        role        = "control-plane"
        ip          = module.control_plane.ip
        ssh_command = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${module.control_plane.ip}"
      }
    },
    {
      for k, v in module.workers : k => {
        role        = "worker"
        ip          = v.ip
        ssh_command = "ssh -i ~/.ssh/id_ed25519_sno ubuntu@${v.ip}"
      }
    }
  )
}
