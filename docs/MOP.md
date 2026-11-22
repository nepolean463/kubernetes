# Method of Procedure (MOP)
## Production Deployment, Operation & Teardown Guide

This document is the operational Method of Procedure (MOP) for provisioning, configuring, verifying, maintaining, and tearing down the 3-node Kubernetes cluster on KVM/libvirt.

---

## 1. Document Overview

- **Project:** `k8s-terraform` (Branch: `dual-nic-ceph`)
- **Environment:** Local Ubuntu KVM/libvirt Host (Dual-NIC: Physical Bridge LAN + Isolated KVM Network + Dedicated Ceph Storage)
- **Node Allocations:**
  - Control Plane: `k8s-cp-1`
    - External LAN (`lan0`): `192.168.1.210/24` (Gateway: `192.168.1.1`, SSH, MetalLB, Web)
    - Internal KVM (`internal0`): `10.240.0.10/24` (No Gateway, etcd, apiserver, Flannel)
    - Resources: 2 vCPU, 3072 MiB RAM, 10 GiB disk
  - Worker 1: `k8s-worker-1`
    - External LAN (`lan0`): `192.168.1.211/24` (Gateway: `192.168.1.1`, SSH, MetalLB, Web)
    - Internal KVM (`internal0`): `10.240.0.11/24` (No Gateway, Flannel)
    - Resources: 2 vCPU, 1536 MiB RAM, 10 GiB disk
  - Worker 2: `k8s-worker-2`
    - External LAN (`lan0`): `192.168.1.212/24` (Gateway: `192.168.1.1`, SSH, MetalLB, Web)
    - Internal KVM (`internal0`): `10.240.0.12/24` (No Gateway, Flannel)
    - Resources: 2 vCPU, 1536 MiB RAM, 10 GiB disk
  - Storage Node 1: `k8s-storage-1`
    - External LAN (`lan0`): `192.168.1.215/24` (Gateway: `192.168.1.1`, SSH)
    - Internal KVM (`internal0`): `10.240.0.15/24` (No Gateway, Flannel, Ceph OSD replication)
    - Resources: 2 vCPU, 2048 MiB RAM, 10 GiB root disk (`/dev/vda`) + 5 GiB raw Ceph OSD disk (`/dev/vdb`)
  - Storage Node 2: `k8s-storage-2`
    - External LAN (`lan0`): `192.168.1.216/24` (Gateway: `192.168.1.1`, SSH)
    - Internal KVM (`internal0`): `10.240.0.16/24` (No Gateway, Flannel, Ceph OSD replication)
    - Resources: 2 vCPU, 2048 MiB RAM, 10 GiB root disk (`/dev/vda`) + 5 GiB raw Ceph OSD disk (`/dev/vdb`)
  - Storage Node 3: `k8s-storage-3`
    - External LAN (`lan0`): `192.168.1.217/24` (Gateway: `192.168.1.1`, SSH)
    - Internal KVM (`internal0`): `10.240.0.17/24` (No Gateway, Flannel, Ceph OSD replication)
    - Resources: 2 vCPU, 2048 MiB RAM, 10 GiB root disk (`/dev/vda`) + 5 GiB raw Ceph OSD disk (`/dev/vdb`)
- **Pod Network CIDR:** `10.244.0.0/16` (Flannel CNI bound to `--iface-regex=10.240.0.*`)
- **MetalLB LoadBalancer Pool:** `192.168.1.220 - 192.168.1.230` (Layer 2 announced on `lan0`)
- **Ceph StorageClass:** `rook-ceph-block` (RBD dynamic 3-replica PVC provisioning)
- **Kubernetes Version:** `v1.35.10`

---

## 1.1. Dual-NIC Architecture & Node Address Design

### A. Network Separation & Routing
Each VM has two network interfaces attached:
1. **`lan0` (External Physical Bridge `bridge0`):**
   - Configured with static IP in `192.168.1.0/24`.
   - Contains the **only default gateway** (`192.168.1.1`) and DNS resolvers.
   - Used for host SSH management, Ansible automation, outbound internet access (package installs, container image pulls), and MetalLB LoadBalancer service VIPs.
2. **`internal0` (Internal KVM Virtual Network `virbr1`):**
   - Configured with static IP in `10.240.0.0/24`.
   - **Crucial:** **No default gateway** is assigned to prevent asymmetric routing conflicts.
   - Dedicated exclusively to Kubernetes cluster-internal control and data traffic:
     - `kubelet` registers with `--node-ip=10.240.0.1x`.
     - `kube-apiserver` binds and advertises on `--apiserver-advertise-address=10.240.0.10` (with `192.168.1.210` included in TLS SANs).
     - `etcd` peer and client traffic runs exclusively on `10.240.0.10`.
     - Flannel CNI encapsulates pod overlay traffic across the `10.240.0.x` interface.

### B. Understanding `INTERNAL-IP` vs `EXTERNAL-IP` in `kubectl get nodes`
When querying nodes with `kubectl get nodes -o wide`:
```
NAME           STATUS   ROLES           AGE   VERSION    INTERNAL-IP   EXTERNAL-IP   ...
k8s-cp-1       Ready    control-plane   25m   v1.35.10   10.240.0.10   <none>        ...
k8s-worker-1   Ready    <none>          25m   v1.35.10   10.240.0.11   <none>        ...
k8s-worker-2   Ready    <none>          25m   v1.35.10   10.240.0.12   <none>        ...
```

1. **Why `INTERNAL-IP` shows `10.240.0.1x`:**
   - In bare-metal clusters, `kubelet` discovers or is instructed via `--node-ip` which IP to report as `InternalIP`. By specifying `KUBELET_EXTRA_ARGS="--node-ip=10.240.0.1x"`, all intra-cluster pod-to-pod and node-to-node routing is locked to the high-speed isolated KVM internal bridge.
2. **Why `EXTERNAL-IP` shows `<none>`:**
   - In upstream Kubernetes, the `ExternalIP` field on nodes is **specifically reserved for Cloud Controller Managers (CCM)** (e.g., AWS, GCP, Azure, OpenStack).
   - `kubelet`'s `--node-ip` flag only accepts a single IP or a dual-stack IPv4/IPv6 pair (e.g. `10.240.0.10,2001:db8::1`). Passing two IPv4 addresses causes kubelet to fail on startup.
   - Without an external cloud provider, `kubelet` is the sole authority over `status.addresses`. Kubelet periodically runs a heartbeat sync (every 10s) and overwrites the node address list with `[InternalIP, Hostname]`. Any third-party attempts to patch `ExternalIP` directly into `status.addresses` trigger continuous reconciliation loops and etcd churn.
   - Therefore, in bare-metal and on-prem Kubernetes, **`EXTERNAL-IP: <none>` is the standard, expected, and correct behavior**.
3. **How External Node IPs and Services are Handled:**
   - **Service Access (MetalLB):** User traffic from the LAN does not target individual node internal IPs; it targets MetalLB LoadBalancer VIPs (e.g. `https://192.168.1.220`), which MetalLB announces on `lan0` using Layer 2 ARP.
   - **Node Visibility (Labels):** To inspect and track external LAN IPs on node objects without reconciliation conflicts, the playbook labels each node with `node.kubernetes.io/external-ip`:
     ```bash
     kubectl get nodes -L node.kubernetes.io/external-ip -o wide
     ```

---

## 1.2. Architecture Selection & Git Branching Strategy

This repository maintains two operational architectures via Git branches:

- **`main` Branch (Single-NIC):** Baseline architecture where all VMs attach solely to `bridge0` (`192.168.1.0/24`). All Kubernetes services, control plane, and overlay traffic share the physical LAN.
- **`dual-nic` Branch (Dual-NIC):** Advanced architecture where each VM has two network interfaces (`lan0` for physical LAN access and `internal0` for isolated KVM cluster communication).

### Switching Procedure:
1. **Always clean up active VM state before switching branches:**
   ```bash
   cd ~/k8s-terraform
   terraform destroy -auto-approve
   ssh-keygen -R 192.168.1.210 2>/dev/null
   ssh-keygen -R 192.168.1.211 2>/dev/null
   ssh-keygen -R 192.168.1.212 2>/dev/null
   rm -f kubeconfig ~/.kube/config
   ```
2. **Switch to desired branch:**
   ```bash
   # For Single-NIC:
   git checkout main

   # For Dual-NIC:
   git checkout dual-nic
   ```
3. **Provision and bootstrap:**
   ```bash
   terraform apply -auto-approve
   cd ansible && source .venv/bin/activate
   ansible-playbook -i inventory.ini site.yml
   ```

---

## 2. Phase 1: Pre-Flight Verification

Execute these pre-checks on the hypervisor host before initiating deployment:

```bash
# 1. Verify libvirt hypervisor connection
virsh uri
# Expected: qemu:///system

# 2. Verify physical bridge interface is active
ip -br addr show bridge0
# Expected: UP with valid IP (e.g. 192.168.1.x/24)

# 3. Confirm bridge-nf-call-iptables is disabled to prevent packet drops
cat /proc/sys/net/bridge/bridge-nf-call-iptables
# Expected: 0

# 4. Verify SSH key existence
ls -la ~/.ssh/id_ed25519_sno ~/.ssh/id_ed25519_sno.pub
```

---

## 3. Phase 2: Configuration & Repository Setup

```bash
cd ~/k8s-terraform

# Copy example variables to active configuration
cp terraform.tfvars.example terraform.tfvars

# Review and edit values (ensure public key string matches your pub key)
# cat ~/.ssh/id_ed25519_sno.pub
nano terraform.tfvars

# (Optional) Pre-cache Ceph Container Images for Fast Rebuilds
# Avoids pulling multi-gigabyte images across 6 VMs simultaneously
./scripts/download-image-cache.sh

# Set up Ansible virtual environment
cd ansible
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install ansible-core
cd ..
```

---

## 4. Phase 3: Infrastructure Deployment (Terraform)

```bash
cd ~/k8s-terraform

# 1. Initialize Terraform providers and child modules
terraform init

# 2. Validate configuration syntax
terraform validate

# 3. Review planned actions
terraform plan

# 4. Apply configuration to provision storage, cloud-init ISOs, and VMs
terraform apply -auto-approve
```

*Expected Result:*
- Libvirt downloads base image (first run only, cached thereafter).
- Thin-provisioned root volumes created under `/var/lib/libvirt/images`.
- 3 VMs booted and bridged to `bridge0`.
- Outputs display node IPs and ready-to-run SSH commands.

---

## 5. Phase 4: Cluster Orchestration (Ansible)

Run the automated bootstrap playbook from the `ansible/` directory.

```bash
cd ~/k8s-terraform/ansible
source .venv/bin/activate

# Execute cluster configuration
ansible-playbook -i inventory.ini site.yml
```

### What the Playbook Executes:
1. **Play 0 (Pre-flight):** Automatically waits for SSH and waits for `cloud-init status --wait` to ensure all user creation and cloud-init bootstrap is complete.
2. **Play 1 (Common):** Pre-caches Ceph container images from `image-cache/ceph-images.tar` into `containerd` on storage/worker nodes, verifies kernel modules (`overlay`, `br_netfilter`, `rbd`), sets sysctls, and disables swap persistently.
3. **Play 2 (Control Plane):** Executes `kubeadm init --pod-network-cidr=10.244.0.0/16`, configures `/home/ubuntu/.kube/config`, deploys Calico CNI, and pulls the cluster admin kubeconfig to the host.
4. **Play 3 (Workers & Storage):** Dynamically retrieves a join token from the control plane and joins worker and storage nodes in parallel.
5. **Play 4 (Verification):** Polls node readiness until all 6 nodes report `Ready`.
6. **Play 5 (Addons - MetalLB & Dashboard):** Configures `strictARP: true` in kube-proxy, deploys MetalLB operator, creates the LAN IP pool (`192.168.1.220-230`), deploys the Kubernetes Dashboard as a LoadBalancer on port `443`, and prints the access URL (`https://192.168.1.220`) and admin token directly in the terminal!
7. **Play 6 (Rook-Ceph Distributed Storage):** Deploys Rook CRDs, Common RBAC, Operator, CephCluster (`3 MONs`, `3 OSDs` on raw `/dev/vdb`), Ceph Block Pool with dynamic `rook-ceph-block (default)` StorageClass, and Ceph toolbox pod.

---

## 6. Phase 5: Post-Deployment Smoke Testing

### A. Check Cluster Nodes and System Pods
```bash
export KUBECONFIG=~/k8s-terraform/kubeconfig

kubectl get nodes -L node.kubernetes.io/external-ip -o wide
kubectl get pods -A
```

### B. Deploy a Test Workload (Nginx Deployment & Service)
```bash
# 1. Create a 2-replica Nginx deployment
kubectl create deployment nginx-test --image=nginx:alpine --replicas=2

# 2. Wait for deployment rollout
kubectl rollout status deployment/nginx-test

# 3. Verify pods are distributed across worker nodes
kubectl get pods -o wide -l app=nginx-test

# 4. Expose deployment as a NodePort service
kubectl expose deployment nginx-test --port=80 --type=NodePort --name=nginx-svc

# 5. Retrieve assigned NodePort
NODE_PORT=$(kubectl get svc nginx-svc -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort assigned: $NODE_PORT"

# 6. Test curl from host machine across node LAN IPs
curl -I http://192.168.1.211:$NODE_PORT
curl -I http://192.168.1.212:$NODE_PORT

# 7. Clean up test deployment
kubectl delete svc nginx-svc
kubectl delete deployment nginx-test
```

### C. Ceph Distributed Storage Verification & Dynamic PVC Smoke Test
```bash
# 1. Verify Ceph health & OSD status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# 2. Verify StorageClass is registered as default
kubectl get storageclass

# 3. Create a dynamic test PVC and mount to a pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-smoke-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
---
apiVersion: v1
kind: Pod
metadata:
  name: ceph-smoke-test-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'Ceph storage works!' > /mnt/data/test.txt && sleep 3600"]
    volumeMounts:
    - mountPath: /mnt/data
      name: test-vol
  volumes:
  - name: test-vol
    persistentVolumeClaim:
      claimName: ceph-smoke-test-pvc
EOF

# 4. Verify PVC bound and Pod Running
kubectl get pvc ceph-smoke-test-pvc
kubectl get pod ceph-smoke-test-pod

# 5. Clean up smoke test resources
kubectl delete pod ceph-smoke-test-pod
kubectl delete pvc ceph-smoke-test-pvc
```

---

## 7. Phase 6: Operational Runbook, Maintenance & Ceph Troubleshooting

### Ceph Storage Operations

#### 1. Tuning Monitor Available Space Warning for Virtual Labs
By default, Ceph monitors alert if host root disk free space is below 15 GiB (`mon_data_avail_warn`). On small lab VMs with 10 GiB root disks, tune this threshold to 10% to achieve pristine `HEALTH_OK`:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph config set mon mon_data_avail_warn 10
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph config set global mon_data_avail_warn 10
```

#### 2. Resolving OSD Memory Pressure on 2 GiB Storage Nodes
If a storage node hosts a MON, MGR, and OSD simultaneously, default Rook requests can exceed 2 GiB allocatable RAM. In `manifests/ceph/cluster.yaml`, ensure requests are scaled for lab environments:
- MON: `requests.memory: 256Mi`
- MGR: `requests.memory: 256Mi`
- OSD: `requests.memory: 512Mi`

#### 3. Clearing Lingering Mon Canary Pods
If Rook's node-validation canary pod lingers in `Terminating`, Kubernetes podAntiAffinity will block the monitor daemon from scheduling on that node. Force-delete the canary to unblock:
```bash
kubectl -n rook-ceph delete pod <mon-canary-pod-name> --force --grace-period=0
```

#### 4. Ceph Toolbox Configuration Generation
The toolbox pod dynamically mounts endpoints from the `rook-ceph-mon-endpoints` ConfigMap and credentials from the `rook-ceph-mon` secret. It automatically writes `/etc/ceph/ceph.conf` and `/etc/ceph/keyring` on boot. If the pod starts before MONs establish quorum, rollout restart it once MONs are ready:
```bash
kubectl -n rook-ceph rollout restart deploy/rook-ceph-tools
```

### Adding a New Worker or Storage Node
1. Edit `variables.tf` (or `terraform.tfvars`) and add an entry under `workers`:
   ```hcl
   "k8s-worker-3" = {
     ip     = "192.168.1.213"
     memory = 2048
     vcpu   = 2
   }
   ```
2. Run `terraform apply -auto-approve`.
3. Add `k8s-worker-3 ansible_host=192.168.1.213` to `ansible/inventory.ini`.
4. Run `ansible-playbook -i inventory.ini site.yml`.

### Daily Cluster Shutdown & Startup (Mini PC Lab)

#### Safe Shutdown Before Powering Off Mini PC:
To prevent etcd and Ceph disk corruption, shut down the cluster in the proper sequence using the automated script:
```bash
./scripts/cluster-shutdown.sh
```
*Sequence:*
1. Sets Ceph `noout` flag to freeze placement groups and avoid rebalancing storms.
2. Gracefully sends ACPI shutdown to workers (`k8s-worker-1..2`) to stop workloads.
3. Gracefully sends ACPI shutdown to storage nodes (`k8s-storage-1..3`) to flush OSD journals.
4. Gracefully shuts down the control plane (`k8s-cp-1`) last.

#### Safe Startup After Powering On Mini PC:
Once the host boots, bring the cluster online in order:
```bash
./scripts/cluster-startup.sh
```
*Sequence:*
1. Starts `k8s-cp-1` and waits for `kube-apiserver` to respond.
2. Starts storage nodes (`k8s-storage-1..3`) and waits for Ceph quorum.
3. Starts worker nodes (`k8s-worker-1..2`).
4. Automatically unsets Ceph `noout` flag and prints node readiness and Ceph health.

---

## 8. Phase 7: Teardown & Clean Rebuild Procedure

### Fast Rebuild (Using Golden Image & Offline Ceph Cache):
```bash
cd ~/k8s-terraform

# 1. Build Golden Base Image once (if not already built)
./scripts/build-golden-image.sh

# 2. Pre-cache Ceph container images on host once (if not already downloaded)
./scripts/download-image-cache.sh

# 3. Destroy active VMs
terraform destroy -auto-approve

# 4. Clear old SSH keys and host kubeconfig
for ip in 210 211 212 215 216 217; do ssh-keygen -R "192.168.1.${ip}" 2>/dev/null; done
rm -f kubeconfig ~/.kube/config

# 5. Re-create VMs (cloud-init finishes in ~5s with 0 MB internet downloads)
terraform apply -auto-approve

# 6. Re-run bootstrap
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```

### Complete Destruction:
```bash
cd ~/k8s-terraform
terraform destroy -auto-approve
```
