output "id" {
  description = "Domain ID"
  value       = libvirt_domain.node.id
}

output "name" {
  description = "Node name"
  value       = libvirt_domain.node.name
}

output "ip" {
  description = "Assigned external LAN static IP address"
  value       = split("/", var.ip_cidr)[0]
}

output "internal_ip" {
  description = "Assigned internal KVM static IP address"
  value       = split("/", var.internal_ip_cidr)[0]
}

output "mac_address" {
  description = "MAC address of external LAN interface"
  value       = var.mac_address
}

output "internal_mac_address" {
  description = "MAC address of internal KVM interface"
  value       = var.internal_mac_address
}
