# Thin-provisioned root disk backed by the Ubuntu 24.04 base image
resource "libvirt_volume" "disk" {
  name     = "${var.node_name}-root.qcow2"
  pool     = var.libvirt_pool
  capacity = var.disk_size

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = var.base_volume_path
    format = {
      type = "qcow2"
    }
  }
}

# Optional secondary raw data disk (e.g. for Ceph OSD)
resource "libvirt_volume" "extra_disk" {
  count    = var.extra_disk_size > 0 ? 1 : 0
  name     = "${var.node_name}-data.qcow2"
  pool     = var.libvirt_pool
  capacity = var.extra_disk_size

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# Cloud-Init ISO generation
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.node_name}-cloudinit"

  meta_data = yamlencode({
    instance-id    = var.node_name
    local-hostname = var.node_name
  })

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname       = var.node_name
    ssh_public_key = var.ssh_public_key
  })

  network_config = templatefile("${path.module}/network-config.yaml.tftpl", {
    ip_cidr              = var.ip_cidr
    mac_address          = var.mac_address
    internal_ip_cidr     = var.internal_ip_cidr
    internal_mac_address = var.internal_mac_address
    gateway              = var.gateway
    dns_servers          = var.dns_servers
  })
}

# Volume for Cloud-Init ISO in the libvirt pool
resource "libvirt_volume" "cloudinit_vol" {
  name = "${var.node_name}-cloudinit.iso"
  pool = var.libvirt_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }

  lifecycle {
    ignore_changes = [
      target
    ]
  }
}

# Virtual Machine Domain
resource "libvirt_domain" "node" {
  name        = var.node_name
  memory      = var.memory
  memory_unit = "MiB"
  vcpu        = var.vcpu
  type        = "kvm"
  running     = true
  autostart   = var.autostart

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type = "hvm"
  }

  devices = {
    disks = concat(
      [
        {
          device = "disk"
          driver = {
            name = "qemu"
            type = "qcow2"
          }
          source = {
            file = {
              file = libvirt_volume.disk.path
            }
          }
          backing_store = {
            format = {
              type = "qcow2"
            }
            source = {
              file = {
                file = var.base_volume_path
              }
            }
          }
          target = {
            dev = "vda"
            bus = "virtio"
          }
        }
      ],
      var.extra_disk_size > 0 ? [
        {
          device = "disk"
          driver = {
            name = "qemu"
            type = "qcow2"
          }
          source = {
            file = {
              file = libvirt_volume.extra_disk[0].path
            }
          }
          backing_store = null
          target = {
            dev = "vdb"
            bus = "virtio"
          }
        }
      ] : [],
      [
        {
          device = "cdrom"
          driver = {
            name = "qemu"
            type = "raw"
          }
          source = {
            file = {
              file = libvirt_volume.cloudinit_vol.path
            }
          }
          backing_store = null
          target = {
            dev = "sda"
            bus = "sata"
          }
        }
      ]
    )

    interfaces = [
      # NIC 1: External LAN Bridge (bridge0)
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_name
          }
        }
        mac = {
          address = var.mac_address
        }
      },
      # NIC 2: Internal KVM Managed Network (k8s-internal)
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.internal_network_name
          }
        }
        mac = {
          address = var.internal_mac_address
        }
      }
    ]

    consoles = [
      {
        type = "pty"
        target = {
          port = 0
          type = "serial"
        }
      }
    ]

    graphics = [
      {
        vnc = {
          listen    = "127.0.0.1"
          auto_port = true
        }
      }
    ]
  }
}
