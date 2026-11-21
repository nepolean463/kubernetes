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
