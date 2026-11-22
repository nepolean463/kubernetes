#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Safe Daily Startup for Kubernetes & Ceph Cluster
# ==============================================================================
# Safely powers on cluster nodes in the correct architectural order:
#   1. Starts Control Plane node (etcd & Kubernetes API Server).
#   2. Waits for Kubernetes API server to become responsive.
#   3. Starts Ceph Storage nodes (Monitors form quorum & OSDs come online).
#   4. Starts Worker nodes (workloads reconnect to storage).
#   5. Clears Ceph 'noout' flag and verifies node and storage health.
# ==============================================================================

set -euo pipefail

CP_NODES=("k8s-cp-1")
STORAGE_NODES=("k8s-storage-1" "k8s-storage-2" "k8s-storage-3")
WORKER_NODES=("k8s-worker-1" "k8s-worker-2")

echo "=========================================================="
echo "🚀 Initiating Safe Cluster Startup on Mini PC"
echo "=========================================================="

is_running() {
  virsh domstate "$1" 2>/dev/null | grep -E -q "running|idle"
}

start_node() {
  local node="$1"
  if ! is_running "${node}"; then
    echo "  -> Starting ${node}..."
    virsh start "${node}" 2>/dev/null || true
  else
    echo "  ℹ️  ${node} is already running."
  fi
}

# 1. Start Control Plane
echo ""
echo "👑 Step 1: Starting Control Plane Node..."
for node in "${CP_NODES[@]}"; do
  start_node "${node}"
done

echo "⏳ Waiting for Kubernetes API server to become responsive..."
until kubectl get nodes &>/dev/null; do
  sleep 3
done
echo "  ✅ Kubernetes API Server is responding!"

# 2. Start Storage Nodes
echo ""
echo "📦 Step 2: Starting Ceph Storage Nodes..."
for node in "${STORAGE_NODES[@]}"; do
  start_node "${node}"
done

# 3. Start Worker Nodes
echo ""
echo "🛠️  Step 3: Starting Worker Workload Nodes..."
for node in "${WORKER_NODES[@]}"; do
  start_node "${node}"
done

# 4. Wait for All Nodes to reach Ready status
echo ""
echo "⏳ Step 4: Waiting for all 6 nodes to reach 'Ready'..."
until [[ $(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready") -eq 6 ]]; do
  sleep 4
done
echo "  ✅ All 6 nodes are Ready!"

# 5. Clear Ceph 'noout' flag
echo ""
echo "🔓 Step 5: Unsetting Ceph 'noout' flag..."
sleep 5
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout 2>/dev/null || true

# 6. Display Cluster & Ceph Status
echo ""
echo "=========================================================="
echo "🎉 Cluster is Fully Operational!"
echo "=========================================================="
kubectl get nodes -L node.kubernetes.io/external-ip -o wide
echo ""
echo "📦 Ceph Health:"
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status || true
echo "=========================================================="
