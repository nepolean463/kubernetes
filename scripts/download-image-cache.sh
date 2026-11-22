#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Pre-download & Cache Ceph Container Images on Host
# ==============================================================================
# Saves the core Rook-Ceph and Ceph container images locally into:
#   image-cache/ceph-images.tar
#
# When present, the Ansible playbook (ansible/site.yml) automatically imports
# this tarball into containerd on every worker and storage node, avoiding:
#   1. Multi-gigabyte redundant downloads across nodes.
#   2. Docker Hub anonymous rate limits.
#   3. Network saturation & TLS handshake timeouts.
#
# If this file is NOT present, Ansible and Kubernetes simply fall back to
# standard online image pulls with zero configuration needed.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${ROOT_DIR}/image-cache"
CACHE_FILE="${CACHE_DIR}/ceph-images.tar"

ROOK_IMAGE="docker.io/rook/ceph:v1.15.5"
CEPH_IMAGE="quay.io/ceph/ceph:v18.2.4"
CSI_IMAGE="quay.io/cephcsi/cephcsi:v3.12.2"
CSI_REGISTRAR="registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.11.1"
CSI_RESIZER="registry.k8s.io/sig-storage/csi-resizer:v1.11.1"
CSI_PROVISIONER="registry.k8s.io/sig-storage/csi-provisioner:v5.0.1"
CSI_SNAPSHOTTER="registry.k8s.io/sig-storage/csi-snapshotter:v8.0.1"
CSI_ATTACHER="registry.k8s.io/sig-storage/csi-attacher:v4.6.1"

echo "=========================================================="
echo "📦 Ceph Container Image Cache Downloader"
echo "=========================================================="

if ! command -v docker &>/dev/null; then
  echo "❌ Error: Docker is required on the host to pull and save images."
  echo "Please install docker or start the docker daemon, then re-run."
  exit 1
fi

mkdir -p "${CACHE_DIR}"

IMAGES=(
  "${ROOK_IMAGE}"
  "${CEPH_IMAGE}"
  "${CSI_IMAGE}"
  "${CSI_REGISTRAR}"
  "${CSI_RESIZER}"
  "${CSI_PROVISIONER}"
  "${CSI_SNAPSHOTTER}"
  "${CSI_ATTACHER}"
)

echo "⬇️  Pulling images..."
for img in "${IMAGES[@]}"; do
  echo "  -> Pulling ${img}..."
  docker pull "${img}"
done

echo "💾 Saving images to ${CACHE_FILE}..."
docker save "${IMAGES[@]}" -o "${CACHE_FILE}"

echo "=========================================================="
echo "✅ Image cache created successfully!"
echo "📍 Location: ${CACHE_FILE}"
ls -lh "${CACHE_FILE}"
echo "=========================================================="
echo "Ansible will now automatically pre-load these images during"
echo "'ansible-playbook -i inventory.ini site.yml'."
echo "=========================================================="
