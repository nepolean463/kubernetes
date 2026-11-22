# External LAN Bridge network attached to host physical bridge0
resource "libvirt_network" "k8s_bridge" {
  name      = var.network_name
  autostart = true

  forward = {
    mode = "bridge"
  }

  bridge = {
    name = var.host_bridge
  }
}

# Internal KVM-managed isolated network for inter-node and Kubernetes cluster traffic
resource "libvirt_network" "k8s_internal" {
  name      = var.internal_network_name
  autostart = true

  forward = {
    mode = "nat"
  }

  domain = {
    name = "k8s.internal"
  }

  ips = [
    {
      address = "10.240.0.1"
      netmask = "255.255.255.0"
      dhcp = {
        ranges = [
          {
            start = "10.240.0.100"
            end   = "10.240.0.200"
          }
        ]
      }
    }
  ]
}
