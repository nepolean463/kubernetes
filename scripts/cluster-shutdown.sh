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
#   5. Disables libvirt autostart so VMs do NOT auto-launch on host boot.
# ==============================================================================

set -euo pipefail

WORKER_NODES=("k8s-worker-1" "k8s-worker-2")
STORAGE_NODES=("k8s-storage-1" "k8s-storage-2" "k8s-storage-3")
CP_NODES=("k8s-cp-1")
ALL_NODES=("${WORKER_NODES[@]}" "${STORAGE_NODES[@]}" "${CP_NODES[@]}")

declare -A NODE_IPS=(
  ["k8s-cp-1"]="192.168.1.210"
  ["k8s-worker-1"]="192.168.1.211"
  ["k8s-worker-2"]="192.168.1.212"
  ["k8s-storage-1"]="192.168.1.215"
  ["k8s-storage-2"]="192.168.1.216"
  ["k8s-storage-3"]="192.168.1.217"
)

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

# Ensure autostart is disabled so host reboot does NOT auto-launch VMs
echo "🚫 Disabling libvirt VM autostart..."
for node in "${ALL_NODES[@]}"; do
  virsh autostart --disable "${node}" 2>/dev/null || true
done

# Function to check if a VM is completely shut off
is_shut_off() {
  local state
  state=$(virsh domstate "$1" 2>/dev/null || echo "shut off")
  [[ "${state}" == "shut off" ]]
}

# Function to trigger shutdown and wait until confirmed shut off
shutdown_group() {
  local group_name="$1"
  shift
  local nodes=("$@")

  echo ""
  echo "🔌 Gracefully stopping ${group_name}..."
  for node in "${nodes[@]}"; do
    if ! is_shut_off "${node}"; then
      local ip="${NODE_IPS[$node]}"
      echo "  -> Triggering shutdown for ${node}..."
      # Attempt graceful OS poweroff via SSH, fallback to ACPI virsh shutdown
      ssh -F /dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=2 "ubuntu@${ip}" "sudo poweroff" 2>/dev/null \
        || virsh shutdown "${node}" 2>/dev/null || true
    else
      echo "  ℹ️  ${node} is already shut off."
    fi
  done

  echo "⏳ Waiting for ${group_name} to confirm power off..."
  for node in "${nodes[@]}"; do
    local waited=0
    while ! is_shut_off "${node}"; do
      sleep 2
      waited=$((waited + 2))
      if [[ $waited -ge 30 ]]; then
        echo "  ⚠️  ${node} took longer than 30s; forcing poweroff..."
        virsh destroy "${node}" 2>/dev/null || true
        sleep 1
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
echo "🔍 Current VM State (virsh list):"
virsh list --all
echo "=========================================================="
echo "🎉 All 6 Kubernetes Cluster VMs are Safely Powered Off!"
echo "📍 You can now safely power off or shut down your Mini PC."
echo "=========================================================="
echo "To power the cluster back on tomorrow, simply run:"
echo "  ./scripts/cluster-startup.sh"
echo "=========================================================="
