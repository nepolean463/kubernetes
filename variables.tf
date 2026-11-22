variable "libvirt_uri" {
  type        = string
  description = "The libvirt daemon connection URI"
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  type        = string
  description = "The libvirt storage pool name where volumes are stored"
  default     = "default"
}

variable "host_bridge" {
  type        = string
  description = "The host bridge network interface name attached to LAN"
  default     = "bridge0"
}

variable "network_name" {
  type        = string
  description = "The libvirt network name for the LAN bridge"
  default     = "k8s-lan-bridge"
}

variable "internal_network_name" {
  type        = string
  description = "Name of the KVM managed internal network"
  default     = "k8s-internal"
}

variable "base_image_name" {
  type        = string
  description = "Name of the base Ubuntu qcow2 volume in libvirt storage pool"
  default     = "ubuntu-24.04-noble-base.qcow2"
}

variable "base_image_url" {
  type        = string
  description = "URL of the official Ubuntu 24.04 LTS Noble cloud image"
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "gateway" {
  type        = string
  description = "Default LAN gateway IP address"
  default     = "192.168.1.1"
}

variable "dns_servers" {
  type        = list(string)
  description = "List of upstream DNS servers"
  default     = ["8.8.8.8", "1.1.1.1"]
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the host SSH public key file"
  default     = "~/.ssh/id_ed25519_sno.pub"
}

variable "ssh_public_key" {
  type        = string
  description = "Raw SSH public key string (if empty, automatically reads from ssh_public_key_path)"
  default     = ""
}

variable "control_plane" {
  type = object({
    name             = string
    vcpu             = number
    memory           = number
    disk_size        = number
    ip_cidr          = string
    mac_address      = string
    internal_ip_cidr = string
    internal_mac     = string
  })
  description = "Hardware specifications and networking for the Kubernetes control plane node"
  default = {
    name             = "k8s-cp-1"
    vcpu             = 2
    memory           = 4096
    disk_size        = 21474836480 # 20 GiB in bytes
    ip_cidr          = "192.168.1.210/24"
    mac_address      = "52:54:00:10:01:10"
    internal_ip_cidr = "10.240.0.10/24"
    internal_mac     = "52:54:00:20:01:10"
  }
}

variable "workers" {
  type = map(object({
    vcpu             = number
    memory           = number
    disk_size        = number
    ip_cidr          = string
    mac_address      = string
    internal_ip_cidr = string
    internal_mac     = string
  }))
  description = "Hardware specifications and networking for the Kubernetes worker nodes"
  default = {
    "k8s-worker-1" = {
      vcpu             = 2
      memory           = 2048
      disk_size        = 21474836480 # 20 GiB in bytes
      ip_cidr          = "192.168.1.211/24"
      mac_address      = "52:54:00:10:01:11"
      internal_ip_cidr = "10.240.0.11/24"
      internal_mac     = "52:54:00:20:01:11"
    }
    "k8s-worker-2" = {
      vcpu             = 2
      memory           = 2048
      disk_size        = 21474836480 # 20 GiB in bytes
      ip_cidr          = "192.168.1.212/24"
      mac_address      = "52:54:00:10:01:12"
      internal_ip_cidr = "10.240.0.12/24"
      internal_mac     = "52:54:00:20:01:12"
    }
  }
}

variable "storage_nodes" {
  type = map(object({
    vcpu             = number
    memory           = number
    disk_size        = number
    extra_disk_size  = number
    ip_cidr          = string
    mac_address      = string
    internal_ip_cidr = string
    internal_mac     = string
  }))
  description = "Hardware specifications and networking for dedicated Kubernetes Ceph storage nodes"
  default = {
    "k8s-storage-1" = {
      vcpu             = 2
      memory           = 3072          # 3 GiB RAM for Ceph OSD & Mon
      disk_size        = 21474836480   # 20 GiB root disk
      extra_disk_size  = 16106127360   # 15 GiB raw Ceph OSD disk (15 * 1024^3)
      ip_cidr          = "192.168.1.215/24"
      mac_address      = "52:54:00:10:01:15"
      internal_ip_cidr = "10.240.0.15/24"
      internal_mac     = "52:54:00:20:01:15"
    }
  }
}
