output "id" {
  description = "Domain ID"
  value       = libvirt_domain.node.id
}

output "name" {
  description = "Node name"
  value       = libvirt_domain.node.name
}

output "ip" {
  description = "Assigned static IP address"
  value       = split("/", var.ip_cidr)[0]
}
