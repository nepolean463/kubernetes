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
1. **Play 0 (Pre-flight):** Automatically waits for SSH and waits for `cloud-init status --wait` to ensure all user creation and sudo permissions are active.
2. **Play 1 (Common):** Configures kernel modules (`overlay`, `br_netfilter`), sets sysctls, disables swap persistently, installs `containerd` with `SystemdCgroup = true`, and sets up the Kubernetes v1.35 APT repository.
3. **Play 2 (Control Plane):** Executes `kubeadm init --pod-network-cidr=10.244.0.0/16`, configures `/home/ubuntu/.kube/config`, deploys Flannel CNI, and pulls the cluster admin kubeconfig to the host.
4. **Play 3 (Workers):** Dynamically retrieves a join token from the control plane and joins worker nodes.
5. **Play 4 (Verification):** Polls node readiness until all 3 nodes report `Ready`.
6. **Play 5 (Addons - MetalLB & Dashboard):** Configures `strictARP: true` in kube-proxy, deploys MetalLB operator, creates the LAN IP pool (`192.168.1.220-230`), deploys the Kubernetes Dashboard as a LoadBalancer on port `443`, and prints the access URL (`https://192.168.1.220`) and admin token directly in the terminal!

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

---

## 7. Phase 6: Operational Runbook & Maintenance

### Adding a New Worker Node
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

### Restarting / Powering Off Cluster
To safely shut down the cluster:
```bash
virsh shutdown k8s-worker-1
virsh shutdown k8s-worker-2
virsh shutdown k8s-cp-1
```

To power on the cluster:
```bash
virsh start k8s-cp-1
virsh start k8s-worker-1
virsh start k8s-worker-2
```

---

## 8. Phase 7: Teardown & Clean Rebuild Procedure

### Fast Rebuild (Preserves Base Image Cache):
```bash
cd ~/k8s-terraform

# 1. Destroy VMs and root disks
terraform destroy -target=module.control_plane -target=module.workers -auto-approve

# 2. Clear old SSH keys and host kubeconfig
ssh-keygen -R 192.168.1.210 2>/dev/null
ssh-keygen -R 192.168.1.211 2>/dev/null
ssh-keygen -R 192.168.1.212 2>/dev/null
rm -f kubeconfig ~/.kube/config

# 3. Re-create VMs
terraform apply -auto-approve

# 4. Re-run bootstrap
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```

### Complete Destruction:
```bash
cd ~/k8s-terraform
terraform destroy -auto-approve
```
