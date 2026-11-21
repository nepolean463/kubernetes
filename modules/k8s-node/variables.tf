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
  description = "Name of the libvirt network to attach to"
}

variable "ip_cidr" {
  type        = string
  description = "Static IPv4 CIDR address (e.g. 192.168.1.210/24)"
}

variable "gateway" {
  type        = string
  description = "Default gateway IPv4 address"
}

variable "dns_servers" {
  type        = list(string)
  description = "List of DNS nameservers"
}

variable "ssh_public_key" {
  type        = string
  description = "Authorized SSH public key content"
}
