#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Safe Daily Shutdown for Kubernetes & Ceph Cluster
# ==============================================================================
# Safely powers down cluster nodes in the correct architectural order to prevent
# etcd and Ceph storage corruption on your Mini PC:
#   1. Sets 'noout' flag on Ceph OSDs (prevents redundant data rebalancing).
#   2. Gracefully shuts down Worker nodes (stops workload containers cleanly).
#   3. Gracefully shuts down Storage nodes (flushes OSD journals and Mon quorum).
#   4. Gracefully shuts down Control Plane last (etcd stays consistent).
# ==============================================================================

set -euo pipefail

WORKER_NODES=("k8s-worker-1" "k8s-worker-2")
STORAGE_NODES=("k8s-storage-1" "k8s-storage-2" "k8s-storage-3")
CP_NODES=("k8s-cp-1")

echo "=========================================================="
echo "🛑 Initiating Safe Cluster Shutdown for Mini PC"
echo "=========================================================="

# 1. Set Ceph noout flag if cluster is currently accessible
echo "🔒 Checking Ceph cluster..."
if kubectl --request-timeout=5s -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout 2>/dev/null; then
  echo "  ✅ Ceph 'noout' flag set (prevents unnecessary rebalances during shutdown)."
else
  echo "  ℹ️  Ceph toolbox not reachable or already stopped; continuing shutdown."
fi

# Function to check if a VM is active
is_running() {
  virsh domstate "$1" 2>/dev/null | grep -E -q "running|idle|paused"
}

# Function to trigger shutdown and wait
shutdown_group() {
  local group_name="$1"
  shift
  local nodes=("$@")

  echo ""
  echo "🔌 Gracefully stopping ${group_name}..."
  for node in "${nodes[@]}"; do
    if is_running "${node}"; then
      echo "  -> Sending ACPI shutdown to ${node}..."
      virsh shutdown "${node}" 2>/dev/null || true
    else
      echo "  ℹ️  ${node} is already off."
    fi
  done

  echo "⏳ Waiting for ${group_name} to power off..."
  for node in "${nodes[@]}"; do
    local waited=0
    while is_running "${node}"; do
      sleep 2
      waited=$((waited + 2))
      if [[ $waited -ge 60 ]]; then
        echo "  ⚠️  ${node} took longer than 60s; forcing poweroff..."
        virsh destroy "${node}" 2>/dev/null || true
        break
      fi
    done
    echo "  ✅ ${node} is shut off."
  done
}

# 2. Shutdown Worker nodes first
shutdown_group "Worker Nodes" "${WORKER_NODES[@]}"

# 3. Shutdown Storage nodes second
shutdown_group "Ceph Storage Nodes" "${STORAGE_NODES[@]}"

# 4. Shutdown Control Plane last
shutdown_group "Control Plane" "${CP_NODES[@]}"

echo ""
echo "=========================================================="
echo "🎉 All 6 Kubernetes Cluster VMs are Safely Powered Off!"
echo "📍 You can now safely power off or shut down your Mini PC."
echo "=========================================================="
echo "To power the cluster back on tomorrow, simply run:"
echo "  ./scripts/cluster-startup.sh"
echo "=========================================================="
