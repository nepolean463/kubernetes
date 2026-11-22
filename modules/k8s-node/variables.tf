variable "node_name" {
  type        = string
  description = "Hostname and VM domain name"
}

variable "libvirt_pool" {
  type        = string
  description = "Libvirt storage pool name"
  default     = "default"
}

variable "base_volume_path" {
  type        = string
  description = "Host path to the backing base Ubuntu image"
}

variable "disk_size" {
  type        = number
  description = "Capacity of the root qcow2 volume in bytes"
  default     = 21474836480 # 20 GiB
}

variable "extra_disk_size" {
  type        = number
  description = "Capacity of an optional secondary raw data disk in bytes (e.g. for Ceph OSD). If 0, no extra disk is created."
  default     = 0
}

variable "memory" {
  type        = number
  description = "Memory allocation in MiB"
}

variable "vcpu" {
  type        = number
  description = "Number of virtual CPUs"
}

variable "network_name" {
  type        = string
  description = "Name of the external LAN libvirt network"
}

variable "ip_cidr" {
  type        = string
  description = "Static IPv4 CIDR address for external LAN (e.g. 192.168.1.210/24)"
}

variable "mac_address" {
  type        = string
  description = "MAC address for external LAN interface"
}

variable "internal_network_name" {
  type        = string
  description = "Name of the internal KVM libvirt network"
}

variable "internal_ip_cidr" {
  type        = string
  description = "Static IPv4 CIDR address for internal network (e.g. 10.240.0.10/24)"
}

variable "internal_mac_address" {
  type        = string
  description = "MAC address for internal network interface"
}

variable "gateway" {
  type        = string
  description = "Default gateway IPv4 address (only on external interface)"
}

variable "dns_servers" {
  type        = list(string)
  description = "List of DNS nameservers"
}

variable "ssh_public_key" {
  type        = string
  description = "Authorized SSH public key content"
}
