#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Build Kubernetes Golden Base Image for KVM/libvirt
# ==============================================================================
# This script creates an optimized, pre-installed Ubuntu 24.04 LTS "Golden Image"
# containing all required system packages, containerd, and Kubernetes v1.35 binaries.
#
# Uses native qemu-nbd chroot (direct host network & DNS) for 100% reliable builds:
#   1. Zero packages are downloaded from the internet during VM boot.
#   2. Cloud-init finishes in ~5 seconds instead of 3-4 minutes.
#   3. Network bandwidth usage is 0 MB.
#   4. Rebuilding the cluster is completely offline and instant.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
OUTPUT_DIR="/var/lib/libvirt/images"
TARGET_IMAGE="${OUTPUT_DIR}/ubuntu-24.04-k8s-golden.qcow2"
TEMP_BUILD_DIR="$(mktemp -d -t k8s-golden-build-XXXXXX)"
TEMP_IMAGE="${TEMP_BUILD_DIR}/golden-raw.qcow2"
MOUNT_DIR="${TEMP_BUILD_DIR}/mnt"
NBD_DEV="/dev/nbd0"

cleanup() {
  echo "🧹 Cleaning up temporary build artifacts and mounts..."
  if [[ -e "${MOUNT_DIR}/etc/resolv.conf.bak" ]]; then
    sudo rm -f "${MOUNT_DIR}/etc/resolv.conf" 2>/dev/null || true
    sudo mv -f "${MOUNT_DIR}/etc/resolv.conf.bak" "${MOUNT_DIR}/etc/resolv.conf" 2>/dev/null || true
  fi
  if mountpoint -q "${MOUNT_DIR}/sys" 2>/dev/null; then sudo umount "${MOUNT_DIR}/sys" || true; fi
  if mountpoint -q "${MOUNT_DIR}/proc" 2>/dev/null; then sudo umount "${MOUNT_DIR}/proc" || true; fi
  if mountpoint -q "${MOUNT_DIR}/dev/pts" 2>/dev/null; then sudo umount "${MOUNT_DIR}/dev/pts" || true; fi
  if mountpoint -q "${MOUNT_DIR}/dev" 2>/dev/null; then sudo umount "${MOUNT_DIR}/dev" || true; fi
  if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then sudo umount "${MOUNT_DIR}" || true; fi
  sudo qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true
  rm -rf "${TEMP_BUILD_DIR}"
}
trap cleanup EXIT

echo "=========================================================="
echo "🛠️  Kubernetes Golden Base Image Builder (Native Chroot)"
echo "=========================================================="

# 1. Check prerequisites
if ! command -v qemu-img &>/dev/null || ! command -v qemu-nbd &>/dev/null || ! command -v growpart &>/dev/null; then
  echo "📦 Installing required tools: qemu-utils & cloud-guest-utils..."
  sudo apt-get update && sudo apt-get install -y qemu-utils cloud-guest-utils
fi

# Ensure nbd kernel module is loaded
sudo modprobe nbd max_part=8

# 2. Obtain base cloud image
LOCAL_CACHED_BASE="/var/lib/libvirt/images/ubuntu-24.04-noble-base.qcow2"

if sudo test -f "${LOCAL_CACHED_BASE}"; then
  echo "📦 Found existing base image in libvirt storage pool: ${LOCAL_CACHED_BASE}"
  echo "Copying to build workspace..."
  sudo cp "${LOCAL_CACHED_BASE}" "${TEMP_IMAGE}"
  sudo chown "$(id -u):$(id -g)" "${TEMP_IMAGE}"
else
  echo "⬇️  Downloading official Ubuntu 24.04 Noble cloud image..."
  curl -fsSL -o "${TEMP_IMAGE}" "${BASE_IMAGE_URL}"
fi

# 3. Expand base image to 10G for package staging
echo "📏 Expanding image to 10G..."
qemu-img resize "${TEMP_IMAGE}" 10G

# 4. Prepare configs on host
echo "🔑 Preparing configuration files and Kubernetes v1.35 signing key..."
KEYRING_FILE="${TEMP_BUILD_DIR}/kubernetes-apt-keyring.gpg"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | gpg --dearmor --yes -o "${KEYRING_FILE}"

K8S_LIST_FILE="${TEMP_BUILD_DIR}/kubernetes.list"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" > "${K8S_LIST_FILE}"

MODULES_FILE="${TEMP_BUILD_DIR}/k8s.conf"
cat << 'EOF' > "${MODULES_FILE}"
overlay
br_netfilter
rbd
EOF

SYSCTL_FILE="${TEMP_BUILD_DIR}/99-kubernetes-cri.conf"
cat << 'EOF' > "${SYSCTL_FILE}"
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

# 5. Connect via NBD and mount
echo "🔌 Connecting image to ${NBD_DEV}..."
sudo qemu-nbd --disconnect "${NBD_DEV}" 2>/dev/null || true
sleep 1
sudo qemu-nbd --connect="${NBD_DEV}" "${TEMP_IMAGE}"
sleep 1

# Detect root partition (matches rootfs label or primary partition)
mkdir -p "${MOUNT_DIR}"
ROOT_DEV=""
for p in "${NBD_DEV}"p1 "${NBD_DEV}"p2 "${NBD_DEV}p3" "${NBD_DEV}"; do
  if sudo blkid "$p" | grep -q "ext4"; then
    ROOT_DEV="$p"
    break
  fi
done

if [[ -z "${ROOT_DEV}" ]]; then
  echo "❌ Error: Could not detect root ext4 partition on ${NBD_DEV}."
  exit 1
fi

# Expand partition and ext4 filesystem to utilize the resized 10G image
PART_NUM=$(echo "${ROOT_DEV}" | grep -o '[0-9]*$')
if [[ -n "${PART_NUM}" ]]; then
  echo "📐 Growing partition ${PART_NUM} on ${NBD_DEV} to utilize expanded 10G..."
  sudo growpart "${NBD_DEV}" "${PART_NUM}" 2>/dev/null || true
  sudo e2fsck -f -y "${ROOT_DEV}" 2>/dev/null || true
  sudo resize2fs "${ROOT_DEV}"
fi

echo "📂 Mounting ${ROOT_DEV} to ${MOUNT_DIR}..."
sudo mount "${ROOT_DEV}" "${MOUNT_DIR}"

# Bind mounts for native chroot environment (shares host networking)
sudo mount --bind /dev "${MOUNT_DIR}/dev"
sudo mount --bind /dev/pts "${MOUNT_DIR}/dev/pts"
sudo mount --bind /proc "${MOUNT_DIR}/proc"
sudo mount --bind /sys "${MOUNT_DIR}/sys"

# Temporarily set reliable public DNS in resolv.conf for direct DNS resolution
if [[ -L "${MOUNT_DIR}/etc/resolv.conf" || -f "${MOUNT_DIR}/etc/resolv.conf" ]]; then
  sudo mv "${MOUNT_DIR}/etc/resolv.conf" "${MOUNT_DIR}/etc/resolv.conf.bak"
fi
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee "${MOUNT_DIR}/etc/resolv.conf" >/dev/null

# Copy configurations into image
sudo cp "${MODULES_FILE}" "${MOUNT_DIR}/etc/modules-load.d/k8s.conf"
sudo cp "${SYSCTL_FILE}" "${MOUNT_DIR}/etc/sysctl.d/99-kubernetes-cri.conf"
sudo mkdir -p "${MOUNT_DIR}/etc/apt/keyrings" "${MOUNT_DIR}/etc/apt/sources.list.d"
sudo cp "${KEYRING_FILE}" "${MOUNT_DIR}/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
sudo chmod 644 "${MOUNT_DIR}/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
sudo cp "${K8S_LIST_FILE}" "${MOUNT_DIR}/etc/apt/sources.list.d/kubernetes.list"
sudo chmod 644 "${MOUNT_DIR}/etc/apt/sources.list.d/kubernetes.list"

# 6. Execute package installations and configurations inside chroot
echo "🍳 Baking packages and system configs into image via native chroot..."
sudo chroot "${MOUNT_DIR}" /bin/bash -c "
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y openssh-server apt-transport-https ca-certificates curl gpg containerd socat conntrack ipset ethtool lvm2 xfsprogs kubelet kubeadm kubectl cri-tools
  apt-mark hold kubelet kubeadm kubectl cri-tools
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable containerd kubelet 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  sed -i '/swap/d' /etc/fstab
  systemctl mask swap.target 2>/dev/null || ln -sf /dev/null /etc/systemd/system/swap.target
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
"

# 7. Restore resolv.conf, trim filesystem, and unmount cleanly
echo "🔄 Restoring original resolv.conf and unmounting..."
sudo fstrim -v "${MOUNT_DIR}" 2>/dev/null || true
sudo rm -f "${MOUNT_DIR}/etc/resolv.conf"
if [[ -e "${MOUNT_DIR}/etc/resolv.conf.bak" ]]; then
  sudo mv -f "${MOUNT_DIR}/etc/resolv.conf.bak" "${MOUNT_DIR}/etc/resolv.conf"
else
  sudo ln -sf ../run/systemd/resolve/stub-resolv.conf "${MOUNT_DIR}/etc/resolv.conf"
fi

sudo umount "${MOUNT_DIR}/sys"
sudo umount "${MOUNT_DIR}/proc"
sudo umount "${MOUNT_DIR}/dev/pts"
sudo umount "${MOUNT_DIR}/dev"
sudo umount "${MOUNT_DIR}"
sudo qemu-nbd --disconnect "${NBD_DEV}"
sleep 1

# 8. Compress and copy to libvirt images pool
echo "💾 Compressing and installing golden image to ${TARGET_IMAGE}..."
sudo qemu-img convert -O qcow2 -c "${TEMP_IMAGE}" "${TARGET_IMAGE}"
sudo chmod 644 "${TARGET_IMAGE}"

echo "=========================================================="
echo "🎉 Golden Base Image Built Successfully!"
echo "📍 Location: ${TARGET_IMAGE}"
ls -lh "${TARGET_IMAGE}"
echo "=========================================================="
echo "Terraform is already configured to use this golden image."
echo "You can now run: terraform destroy && terraform apply"
echo "=========================================================="
