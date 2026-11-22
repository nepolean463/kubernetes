# Hypervisor & Host Prerequisites Guide

This document outlines all system, hardware, networking, virtualization, and tooling prerequisites required to deploy the Kubernetes cluster on a clean Ubuntu host machine.

---

## 1. Hardware Requirements

| Component | Minimum | Recommended | Current Project Setup |
| :--- | :--- | :--- | :--- |
| **CPU** | 4 Cores (with Intel VT-x or AMD-V) | 8+ Cores | 4 Cores |
| **RAM** | 16 GiB | 32 GiB | 22 GiB (~18 GiB free) |
| **Storage** | 80 GiB SSD/NVMe | 200 GiB SSD/NVMe | `/var/lib/libvirt/images` |
| **Network** | 1 Gbps Ethernet | 1 Gbps / 2.5 Gbps | Physical bridged LAN |

Verify CPU hardware virtualization support on your host:
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
# Output must be greater than 0
```

---

## 2. Operating System & Hypervisor Packages

### A. Install KVM, QEMU, and Libvirt
Install the virtualization stack:
```bash
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virt-manager \
  ovmf \
  genisoimage
```

### B. Configure Non-Root User Permissions
Add your primary user to the `kvm` and `libvirt` groups so `virsh` and Terraform can interact with `qemu:///system` without `sudo`:
```bash
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt
```

Verify connection:
```bash
virsh uri
# Output should return: qemu:///system
```

### C. Verify Libvirt Storage Pool
Ensure the `default` storage pool exists and is active:
```bash
virsh pool-info default
# If inactive or missing, define and start it:
# sudo virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images
# sudo virsh pool-start default
# sudo virsh pool-autostart default
```

---

## 3. Host Network Bridge Configuration (`bridge0`)

The cluster nodes must attach directly to a host Linux bridge (`bridge0`) to participate on the physical LAN (`192.168.1.0/24`) without double-NAT.

### Netplan Bridge Setup (Ubuntu 22.04 / 24.04)
Identify your physical Ethernet interface name using `ip -br link` (e.g., `enp3s0` or `eth0`).

Edit or create `/etc/netplan/01-netcfg.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp3s0:               # Replace with your actual physical interface name
      dhcp4: no
      dhcp6: no

  bridges:
    bridge0:
      interfaces: [enp3s0] # Attach the physical interface
      dhcp4: no
      dhcp6: no
      addresses:
        - 192.168.1.50/24  # Host static IP on LAN
      routes:
        - to: default
          via: 192.168.1.1 # Your LAN Gateway
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
      parameters:
        stp: false
        forward-delay: 0
```

Apply the netplan configuration:
```bash
sudo netplan apply
```

Verify `bridge0` status:
```bash
ip -br addr show bridge0
# Must show UP and your host IP address
```

---

## 4. Host Firewall & Bridge Netfilter Configuration

Linux kernels route bridge packets through iptables/nftables by default. To prevent host firewalls (like UFW) from blocking bridged VM traffic between nodes:

### A. Load Kernel Module & Disable Bridge Packet Filtering
```bash
sudo modprobe br_netfilter

# Create persistent module configuration
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf

# Allow bridged packets to pass unfiltered on host
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0

# Make persistent
cat <<EOF | sudo tee /etc/sysctl.d/99-bridge.conf
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
sudo sysctl --system
```

### B. Configure UFW (if enabled)
If UFW is running on your host, explicitly allow routed forwarding on `bridge0`:
```bash
sudo ufw route allow in on bridge0 out on bridge0
sudo ufw reload
```

---

## 5. Tooling Prerequisites

### A. Install Terraform (`v1.8.x`+)
```bash
sudo apt update && sudo apt install -y gnupg software-properties-common curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

### B. Install Python 3 & Virtual Environment Tools
```bash
sudo apt install -y python3 python3-pip python3-venv git
```

### C. Install kubectl
```bash
sudo snap install kubectl --classic
# Or via native package repository matching v1.35
```

### D. Generate SSH Key Pair
Create a dedicated ED25519 key for cluster nodes:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_sno -N "" -C "k8s-cluster-admin"
```

Verify the key files exist:
- Private key: `~/.ssh/id_ed25519_sno` (permissions `0600`)
- Public key: `~/.ssh/id_ed25519_sno.pub` (permissions `0644`)

### E. Install Docker (Optional, for Ceph Container Image Pre-caching)
Docker is used on the host to execute `./scripts/download-image-cache.sh`. This helper script downloads and consolidates multi-gigabyte Ceph container images into `image-cache/ceph-images.tar` so Ansible can preload them into `containerd` during cluster creation:
```bash
sudo apt install -y docker.io
sudo usermod -aG docker $USER
```

### F. Install QEMU Utilities & Cloud Guest Utils (for Golden Image Builder)
Required by `./scripts/build-golden-image.sh` to mount images via NBD, grow partitions, and build offline golden images:
```bash
sudo apt install -y qemu-utils cloud-guest-utils
```
