# Local Kubernetes Cluster on KVM/libvirt (Dual-NIC with Ceph Storage)

A modular, production-standard Infrastructure-as-Code (Terraform) and Configuration Management (Ansible) project to provision and bootstrap a 6-node Kubernetes cluster (`v1.35`) with **Dual-NIC separation** and **3 Dedicated Rook-Ceph Distributed Storage Nodes**:
- **External Network (`lan0`):** Attached directly to physical host `bridge0` (`192.168.1.0/24`) for LAN access, SSH, internet routing, and MetalLB LoadBalancer VIPs (`192.168.1.220`).
- **Internal Network (`internal0`):** Attached to an isolated KVM-managed virtual network (`10.240.0.0/24`) dedicated to intra-cluster Kubernetes traffic (`kubelet --node-ip`, `kube-apiserver --advertise-address`, etcd, Flannel CNI overlay, and Ceph storage replication).
- **Dedicated Storage Nodes (`k8s-storage-1..3`):** 3 storage nodes equipped with secondary raw 5 GiB block devices (`/dev/vdb`) orchestrated by **Rook-Ceph** providing 3-replica quorum and dynamic Ceph Block Storage (RBD) Persistent Volumes.

---

## 🏗️ Dual-NIC & Ceph Storage Topology

```
                                      [ Physical LAN: 192.168.1.0/24 ]
                                                      │
                                             [ Host Bridge: bridge0 ]
                                                      │
                ┌───────────────────────┬─────────────┴─────────┬───────────────────────┐
                │ lan0 (External)       │ lan0 (External)       │ lan0 (External)       │ lan0 (External)
        ┌───────▼───────────────┐ ┌─────▼─────────────────┐ ┌───▼───────────────────┐ ┌─▼─────────────────────┐
        │ k8s-cp-1              │ │ k8s-worker-1          │ │ k8s-worker-2          │ │ k8s-storage-1         │
        │ 192.168.1.210/24      │ │ 192.168.1.211/24      │ │ 192.168.1.212/24      │ │ 192.168.1.215/24      │
        │ Gateway: 192.168.1.1  │ │ Gateway: 192.168.1.1  │ │ Gateway: 192.168.1.1  │ │ Gateway: 192.168.1.1  │
        │ (SSH, Web, MetalLB)   │ │ (SSH, Web, MetalLB)   │ │ (SSH, Web, MetalLB)   │ │ (SSH, Web)            │
        ├───────────────────────┤ ├───────────────────────┤ ├───────────────────────┤ ├───────────────────────┤
        │ 10.240.0.10/24        │ │ 10.240.0.11/24        │ │ 10.240.0.12/24        │ │ 10.240.0.15/24        │
        │ internal0 (Internal)  │ │ internal0 (Internal)  │ │ internal0 (Internal)  │ │ internal0 (Internal)  │
        │ (NO Default Gateway)  │ │ (NO Default Gateway)  │ │ (NO Default Gateway)  │ │ (NO Default Gateway)  │
        │                       │ │                       │ │                       │ │ /dev/vdb: 15 GiB raw  │
        └───────▲───────────────┘ └─────▲─────────────────┘ └───▲───────────────────┘ └─▲─────────────────────┘
                │                       │                       │                       │
                └───────────────────────┴───────────────┬───────┴───────────────────────┘
                                                        │
                                     [ KVM Internal Virtual Network ]
                                      Subnet: 10.240.0.0/24 (virbr1)
                                      (etcd, API Server, Flannel CNI, Ceph Storage I/O)
                                                        │
                     ┌──────────────────────────────────┴──────────────────────────────────┐
                     ▼                                                                     ▼
          [ MetalLB Layer 2 Pool ]                                           [ Rook-Ceph Block Storage ]
            Announced on LAN: 192.168.1.220 - 192.168.1.230                   StorageClass: rook-ceph-block
            VIP: https://192.168.1.220 (Dashboard port 443)                   Dynamic PVC Provisioning (RBD)
```

---

## 📚 Detailed Documentation

- **[Hypervisor & Host Prerequisites](docs/PREREQUISITES.md)**: Hardware requirements, KVM/libvirt installation, Netplan `bridge0` setup, UFW/firewall rules, bridge netfilter sysctls, and tooling setup.
- **[Method of Procedure (MOP)](docs/MOP.md)**: Complete production SOP for deployment, pre-flight checks, smoke testing workloads, Day-2 operations, and disaster recovery.

---

## 📁 Repository Layout

```
├── docs/
│   ├── PREREQUISITES.md        # Ubuntu hypervisor, network bridge, and host setup
│   └── MOP.md                  # Method of Procedure (Deployment, Operations, Teardown)
├── manifests/
│   ├── dashboard.yaml          # Kubernetes Dashboard with LoadBalancer on port 443 & admin RBAC
│   ├── metallb-config.yaml     # MetalLB IPAddressPool (192.168.1.220-230) & L2Advertisement
│   └── metallb-native.yaml     # Official MetalLB native operator manifest
├── main.tf                     # Base Ubuntu volume, dual-NIC attachments & module calls
├── network.tf                  # libvirt_network bridge0 and k8s-internal definitions
├── outputs.tf                  # External and Internal Node IP maps, ready-to-run SSH strings
├── providers.tf                # dmacvicar/libvirt (~> 0.9.9) provider definition
├── variables.tf                # Sizing, dual-NIC MACs, IP CIDRs, and zero-config cluster variables
├── terraform.tfvars.example    # Template variable values for custom environments
├── modules/
│   └── k8s-node/               # Reusable KVM VM node module
│       ├── main.tf             # Domain with 2 virtio NICs, disk backing store, cloud-init ISO
│       ├── providers.tf        # Provider requirements for child module
│       ├── variables.tf        # Node module input definitions (dual-NIC parameters)
│       ├── outputs.tf          # Node external/internal IPs and MAC addresses
│       ├── cloud-init.yaml.tftpl   # User config, SSH keys, swap disabling, /etc/hosts mapping
│       └── network-config.yaml.tftpl # Netplan v2 deterministic MAC matching for dual NICs
└── ansible/                    # Production-grade Ansible automation
    ├── ansible.cfg             # SSH pipelining, sudo, inventory configuration
    ├── inventory.ini           # Cluster inventory with ansible_host and internal_ip
    ├── inventory.ini.example   # Example cluster inventory template
    ├── site.yml                # Main orchestrator playbook (pre-flight, k8s, MetalLB, Dashboard)
    └── roles/
        ├── common/             # Kernel modules, sysctl, containerd, kubelet --node-ip
        ├── control_plane/      # kubeadm init on internal IP, extra SANs, Flannel internal CNI
        └── worker/             # Dynamic token extraction & kubeadm join over internal IP
```

---

## 🔀 Choosing Architecture: Single-NIC vs Dual-NIC vs Ceph Storage

This repository provides three complete deployment architectures managed via Git branches:

| Architecture | Git Branch | Network Topology & Storage | Best Used For |
| :--- | :--- | :--- | :--- |
| **Single-NIC** | `main` | 3 Nodes on single `bridge0` (`192.168.1.0/24`). | Simplicity, home labs, flat network setups. |
| **Dual-NIC** | `dual-nic` | 3 Nodes with `lan0` (`192.168.1.0/24`) + `internal0` (`10.240.0.0/24`). | Production realism, control plane network isolation. |
| **Dual-NIC + Ceph** | `dual-nic-ceph` (active) | 6 Nodes (1 CP, 2 Workers, 3 Storage nodes with 5 GiB raw OSD disks) + **Rook-Ceph** 3-replica distributed block storage. | Distributed enterprise storage, stateful workloads with dynamic PVCs. |

### Switching Between Architectures

> [!IMPORTANT]
> When switching between architectures, **always tear down the active cluster first** because the VM network hardware definitions, node counts, and disk attachments differ between branches:

#### To Deploy Dual-NIC with Ceph Storage:
```bash
cd ~/k8s-terraform
# 1. Teardown active cluster & clean keys
terraform destroy -auto-approve
ssh-keygen -R 192.168.1.210 2>/dev/null; ssh-keygen -R 192.168.1.211 2>/dev/null; ssh-keygen -R 192.168.1.212 2>/dev/null; ssh-keygen -R 192.168.1.215 2>/dev/null; rm -f kubeconfig ~/.kube/config

# 2. Switch to dual-nic-ceph branch
git checkout dual-nic-ceph

# 3. Provision and bootstrap (provisions VMs, bootstraps k8s, MetalLB, Dashboard, and Rook-Ceph)
terraform apply -auto-approve
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```

---

## 🚀 Quick Start & Lifecycle Management

### 1. Terraform Infrastructure Provisioning

```bash
cd ~/k8s-terraform

# Review plan & apply (provisions 2 virtual networks, disks, ISOs, and boots 2-NIC VMs)
terraform apply -auto-approve
```

### 2. Ansible Kubernetes & Addon Bootstrap (Zero-Wait)

Run Ansible immediately after `terraform apply`. Playbook Play 0 automatically waits for SSH and `cloud-init` to finish before executing tasks:

```bash
cd ~/k8s-terraform/ansible

# Activate dedicated venv
source .venv/bin/activate

# 1. Test user-level connectivity
ansible -m ping all

# 2. Run full cluster bootstrap, MetalLB, and Dashboard deployment
ansible-playbook -i inventory.ini site.yml
```

At completion, the playbook prints your exact Dashboard URL and admin token directly in the terminal recap!

---

## 🌐 Web Dashboard Access

The **Kubernetes Dashboard** is exposed via MetalLB on standard HTTPS port `443` (no port number needed):

1. Open your browser on any device on your LAN:
   ```
   https://192.168.1.220
   ```
2. Accept the self-signed certificate warning (**Advanced** $\rightarrow$ **Proceed to 192.168.1.220**).
3. Retrieve and paste your admin token:
   ```bash
   kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d && echo
   ```

---

## 🔍 Cluster Access & Operations

### From the Host Machine

`kubectl` connects over the external LAN IP with valid TLS SAN certificates:

```bash
export KUBECONFIG=~/k8s-terraform/kubeconfig

# Query nodes with the external LAN IP label column
kubectl get nodes -L node.kubernetes.io/external-ip -o wide
```

Output:
```
NAME           STATUS   ROLES           AGE   VERSION    INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME    EXTERNAL-IP
k8s-cp-1       Ready    control-plane   28m   v1.35.10   10.240.0.10   <none>        Ubuntu 24.04.5 LTS   6.8.0-147-generic   containerd://2.2.1   192.168.1.210
k8s-worker-1   Ready    <none>          28m   v1.35.10   10.240.0.11   <none>        Ubuntu 24.04.5 LTS   6.8.0-147-generic   containerd://2.2.1   192.168.1.211
k8s-worker-2   Ready    <none>          28m   v1.35.10   10.240.0.12   <none>        Ubuntu 24.04.5 LTS   6.8.0-147-generic   containerd://2.2.1   192.168.1.212
```

#### 💡 Deep Dive: Why is `EXTERNAL-IP` `<none>` in `kubectl get nodes`?
- **Kubelet Status Reconciler:** In Kubernetes, `kubelet` regularly registers its node status with the API server. In bare-metal clusters (without a Cloud Controller Manager), `kubelet` only populates `InternalIP` (set via `--node-ip=10.240.0.1x`) and `Hostname`.
- **Cloud Controller Reservation:** In upstream Kubernetes architecture, `EXTERNAL-IP` is strictly populated by cloud providers (AWS, GCP, Azure) via a Cloud Controller Manager (CCM). On bare-metal and on-prem clusters, **`EXTERNAL-IP: <none>` is standard, expected, and correct behavior**.
- **Dual-Stack Limitation:** Kubelet's `--node-ip` parameter only allows either a single IP or an IPv4+IPv6 dual-stack pair; it explicitly rejects two IPv4 addresses. Furthermore, manually patching `.status.addresses` creates a fight with kubelet's 10-second heartbeat sync, which resets the address list.
- **Production Solution:**
  1. **Workload Ingress:** External access is handled natively at the Service layer by **MetalLB** announcing IP pool `192.168.1.220-230` over `lan0` via Layer 2 ARP, and by NodePort services reachable on the LAN.
  2. **Node Visibility:** Node LAN IPs are permanently tracked using standard Kubernetes labels (`node.kubernetes.io/external-ip`), visible via `-L node.kubernetes.io/external-ip`.

### Node SSH Access

```bash
# Control Plane
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.210

# Worker 1
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.211

# Worker 2
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.212

# Storage Nodes (Ceph OSDs)
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.215  # k8s-storage-1
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.216  # k8s-storage-2
ssh -i ~/.ssh/id_ed25519_sno ubuntu@192.168.1.217  # k8s-storage-3
```

---

## 📦 Ceph Storage Operations & Verification

### 1. Check Ceph Cluster Status
Access the Ceph toolbox to inspect cluster health, MONs, and OSDs:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

Expected healthy output:
```text
  cluster:
    id:     ...
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum a,b,c
    mgr: a(active)
    osd: 3 osds: 3 up, 3 in
```

### 2. Verify StorageClass
```bash
kubectl get storageclass
```
Expected output:
```text
NAME                        PROVISIONER                     RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
rook-ceph-block (default)   rook-ceph.rbd.csi.ceph.com      Delete          Immediate           true                   5m
```

### 3. Test Dynamic PVC Provisioning
Deploy the test PVC and Pod:
```bash
kubectl apply -f manifests/ceph/test-pvc.yaml

# Watch PVC bind to a newly created Ceph block image
kubectl get pvc,pods -l app=ceph-test
```
Cleanup test workload:
```bash
kubectl delete -f manifests/ceph/test-pvc.yaml
```

---

## ⚡ Fast Rebuilds, Golden Images & Offline Caching

To completely eliminate internet dependency and deploy in **seconds with 0 MB internet downloads**:

### 1. Build the Kubernetes Golden Base Image (Zero OS package downloads)
Run the golden image builder script once on your host:
```bash
./scripts/build-golden-image.sh
```
This bakes `containerd`, `kubelet`, `kubeadm`, `kubectl`, `cri-tools`, `lvm2`, `xfsprogs`, and kernel configs directly into `/var/lib/libvirt/images/ubuntu-24.04-k8s-golden.qcow2`.

Enable it in your `terraform.tfvars`:
```hcl
base_image_name = "k8s-cluster-base.qcow2"
base_image_url  = "file:///var/lib/libvirt/images/ubuntu-24.04-k8s-golden.qcow2"
```
*(Using a distinct `base_image_name` ensures `terraform destroy` will never delete your master golden image!)*
*Result: Cloud-init completes in **~5 seconds** instead of 4 minutes, and 0 bytes are downloaded during VM boot.*

### 2. Pre-cache Ceph Container Images (Zero container downloads)
Run the image cache script once on your host:
```bash
./scripts/download-image-cache.sh
```
This saves `image-cache/ceph-images.tar` on your host. Ansible automatically detects it and imports all Ceph images into `containerd` in seconds. If absent, it gracefully falls back to online pulls.

---

## 🔄 Teardown & Clean Rebuild

```bash
# 1. Destroy VMs and disks
terraform destroy -auto-approve

# 2. Clean old SSH host keys from host
ssh-keygen -R 192.168.1.210 2>/dev/null; ssh-keygen -R 192.168.1.211 2>/dev/null; ssh-keygen -R 192.168.1.212 2>/dev/null; ssh-keygen -R 192.168.1.215 2>/dev/null; ssh-keygen -R 192.168.1.216 2>/dev/null; ssh-keygen -R 192.168.1.217 2>/dev/null; rm -f kubeconfig ~/.kube/config

# 3. (Optional) Ensure offline image cache is ready for instant rebuild
# ./scripts/download-image-cache.sh

# 4. Recreate VMs
terraform apply -auto-approve

# 5. Re-run bootstrap (configures k8s, MetalLB, Dashboard, and Ceph)
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```
