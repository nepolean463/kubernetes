# Local Kubernetes Cluster on KVM/libvirt (Dual-NIC Architecture)

A modular, production-standard Infrastructure-as-Code (Terraform) and Configuration Management (Ansible) project to provision and bootstrap a 3-node Kubernetes cluster (`v1.35`) with **Dual-NIC separation**:
- **External Network (`lan0`):** Attached directly to physical host `bridge0` (`192.168.1.0/24`) for LAN access, SSH, internet routing, and MetalLB LoadBalancer VIPs (`192.168.1.220`).
- **Internal Network (`internal0`):** Attached to an isolated KVM-managed virtual network (`10.240.0.0/24`) dedicated to intra-cluster Kubernetes traffic (`kubelet --node-ip`, `kube-apiserver --advertise-address`, etcd, and Flannel CNI overlay).

---

## 🏗️ Dual-NIC Architecture & Topology

```
                              [ Physical LAN: 192.168.1.0/24 ]
                                              │
                                     [ Host Bridge: bridge0 ]
                                              │
                      ┌───────────────────────┼───────────────────────┐
                      │ lan0 (External)       │ lan0 (External)       │ lan0 (External)
              ┌───────▼───────────────┐ ┌─────▼─────────────────┐ ┌───▼───────────────────┐
              │ k8s-cp-1              │ │ k8s-worker-1          │ │ k8s-worker-2          │
              │ 192.168.1.210/24      │ │ 192.168.1.211/24      │ │ 192.168.1.212/24      │
              │ Gateway: 192.168.1.1  │ │ Gateway: 192.168.1.1  │ │ Gateway: 192.168.1.1  │
              │ (SSH, Web, MetalLB)   │ │ (SSH, Web, MetalLB)   │ │ (SSH, Web, MetalLB)   │
              ├───────────────────────┤ ├───────────────────────┤ ├───────────────────────┤
              │ 10.240.0.10/24        │ │ 10.240.0.11/24        │ │ 10.240.0.12/24        │
              │ internal0 (Internal)  │ │ internal0 (Internal)  │ │ internal0 (Internal)  │
              │ (NO Default Gateway)  │ │ (NO Default Gateway)  │ │ (NO Default Gateway)  │
              └───────▲───────────────┘ └─────▲─────────────────┘ └───▲───────────────────┘
                      │                       │                       │
                      └───────────────────────┼───────────────────────┘
                                              │
                             [ KVM Internal Virtual Network ]
                              Subnet: 10.240.0.0/24 (virbr1)
                              (etcd, API Server, Flannel CNI)
                                              │
           ┌──────────────────────────────────┴──────────────────────────────────┐
           ▼                                                                     ▼
[ MetalLB Layer 2 Pool ]                                           [ Kubernetes Web Dashboard ]
  Announced on External LAN: 192.168.1.220 - 192.168.1.230           VIP: https://192.168.1.220 (Port 443)
  Automatic bare-metal LoadBalancer IPs                              Direct browser access from LAN
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
```

---

## 🔄 Teardown & Clean Rebuild

```bash
# 1. Destroy only the VM instances and disks (keeps ubuntu base image cached)
terraform destroy -target=module.control_plane -target=module.workers -auto-approve

# 2. Clean old SSH host keys from host
ssh-keygen -R 192.168.1.210 2>/dev/null; ssh-keygen -R 192.168.1.211 2>/dev/null; ssh-keygen -R 192.168.1.212 2>/dev/null; rm -f kubeconfig ~/.kube/config

# 3. Recreate VMs in ~10 seconds
terraform apply -auto-approve

# 4. Re-run bootstrap
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```
