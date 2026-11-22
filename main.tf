locals {
  ssh_public_key = var.ssh_public_key != "" ? var.ssh_public_key : (
    fileexists(pathexpand(var.ssh_public_key_path)) ? file(pathexpand(var.ssh_public_key_path)) : ""
  )
}

# Base Ubuntu 24.04 LTS Cloud Image volume in the libvirt storage pool
resource "libvirt_volume" "ubuntu_base" {
  name = var.base_image_name
  pool = var.libvirt_pool

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.base_image_url
    }
  }
}

# Kubernetes Control Plane Node
module "control_plane" {
  source = "./modules/k8s-node"

  node_name             = var.control_plane.name
  libvirt_pool          = var.libvirt_pool
  base_volume_path      = libvirt_volume.ubuntu_base.path
  disk_size             = var.control_plane.disk_size
  memory                = var.control_plane.memory
  vcpu                  = var.control_plane.vcpu
  network_name          = libvirt_network.k8s_bridge.name
  ip_cidr               = var.control_plane.ip_cidr
  mac_address           = var.control_plane.mac_address
  internal_network_name = libvirt_network.k8s_internal.name
  internal_ip_cidr      = var.control_plane.internal_ip_cidr
  internal_mac_address  = var.control_plane.internal_mac
  gateway               = var.gateway
  dns_servers           = var.dns_servers
  ssh_public_key        = local.ssh_public_key

  depends_on = [
    libvirt_volume.ubuntu_base,
    libvirt_network.k8s_bridge,
    libvirt_network.k8s_internal
  ]
}

# Kubernetes Worker Nodes (provisioned using for_each)
module "workers" {
  for_each = var.workers
  source   = "./modules/k8s-node"

  node_name             = each.key
  libvirt_pool          = var.libvirt_pool
  base_volume_path      = libvirt_volume.ubuntu_base.path
  disk_size             = each.value.disk_size
  memory                = each.value.memory
  vcpu                  = each.value.vcpu
  network_name          = libvirt_network.k8s_bridge.name
  ip_cidr               = each.value.ip_cidr
  mac_address           = each.value.mac_address
  internal_network_name = libvirt_network.k8s_internal.name
  internal_ip_cidr      = each.value.internal_ip_cidr
  internal_mac_address  = each.value.internal_mac
  gateway               = var.gateway
  dns_servers           = var.dns_servers
  ssh_public_key        = local.ssh_public_key

  depends_on = [
    libvirt_volume.ubuntu_base,
    libvirt_network.k8s_bridge,
    libvirt_network.k8s_internal
  ]
}
