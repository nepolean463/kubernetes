# Local Kubernetes Cluster on KVM/libvirt with Terraform & Ansible

A modular, production-standard Infrastructure-as-Code (Terraform) and Configuration Management (Ansible) project to provision and bootstrap a 3-node Kubernetes cluster (`v1.35`) on local KVM/libvirt.

All nodes are bridged directly to the host's physical network via `bridge0` (`192.168.1.0/24`). Includes **MetalLB** bare-metal Layer 2 load balancing and the **Kubernetes Web Dashboard** exposed on standard HTTPS port `443`.

---

## 🏗️ Architecture & Topology

```
                       [ LAN / Physical Network: 192.168.1.0/24 ]
                                        │
                               [ Host Bridge: bridge0 ]
                                        │
    ┌───────────────────────────────────┼───────────────────────────────────┐
    │                                   │                                   │
┌───▼─────────────────────┐ ┌───────────▼─────────┐ ┌───────────────────────▼───┐
│ k8s-cp-1                │ │ k8s-worker-1        │ │ k8s-worker-2              │
│ 192.168.1.210           │ │ 192.168.1.211       │ │ 192.168.1.212             │
│ Control Plane (v1.35)   │ │ Worker Node (v1.35) │ │ Worker Node (v1.35)       │
│ 2 vCPU / 4096 MiB RAM   │ │ 2 vCPU / 2048 MiB   │ │ 2 vCPU / 2048 MiB         │
│ Flannel CNI             │ │ containerd runtime  │ │ containerd runtime        │
└─────────────────────────┘ └─────────────────────┘ └───────────────────────────┘
                                        │
           ┌────────────────────────────┴────────────────────────────┐
           ▼                                                         ▼
[ MetalLB Layer 2 Pool ]                               [ Kubernetes Web Dashboard ]
  IP Range: 192.168.1.220 - 192.168.1.230                VIP: https://192.168.1.220 (Port 443)
  Automatic bare-metal LoadBalancer IPs                  Full OpenShift-like UI experience
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
├── main.tf                     # Base Ubuntu volume & module invocations
├── network.tf                  # libvirt_network bridge0 mapping
├── outputs.tf                  # Node IP maps and ready-to-run SSH strings
├── providers.tf                # dmacvicar/libvirt (~> 0.9.9) provider definition
├── variables.tf                # Sizing, networking, and zero-config cluster variables
├── terraform.tfvars.example    # Template variable values for custom environments
├── modules/
│   └── k8s-node/               # Reusable KVM VM node module
│       ├── main.tf             # Domain, backing store volume, cloud-init ISO
│       ├── providers.tf        # Provider requirements for child module
│       ├── variables.tf        # Node module input definitions
│       ├── outputs.tf          # Node IP and domain outputs
│       ├── cloud-init.yaml.tftpl   # User config, SSH keys, swap disabling
│       └── network-config.yaml.tftpl # Netplan v2 static LAN configuration
└── ansible/                    # Production-grade Ansible automation
    ├── ansible.cfg             # SSH pipelining, sudo, inventory configuration
    ├── inventory.ini           # Cluster inventory (control_plane, workers)
    ├── inventory.ini.example   # Example cluster inventory template
    ├── site.yml                # Main orchestrator playbook (pre-flight, k8s, MetalLB, Dashboard)
    └── roles/
        ├── common/             # Kernel modules, sysctl, containerd, k8s packages
        ├── control_plane/      # kubeadm init, Flannel CNI, kubeconfig fetch
        └── worker/             # Dynamic token extraction & kubeadm join
```

---

## 🚀 Quick Start & Lifecycle Management

### 1. Terraform Infrastructure Provisioning

```bash
cd ~/k8s-terraform

# Review plan & apply (creates disks, ISOs, and boots VMs)
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

`kubectl` is automatically pointed to the generated kubeconfig:

```bash
export KUBECONFIG=~/k8s-terraform/kubeconfig

kubectl get nodes -o wide
kubectl get pods -A
```

### From Other LAN Machines

Copy `~/k8s-terraform/kubeconfig` to your other machines and place it at `~/.kube/config`. The API server endpoint is reachable directly at:
```
https://192.168.1.210:6443
```

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

## 🔄 Fast Cluster Teardown & Rebuild

To completely destroy and rebuild the cluster from scratch in under 2 minutes:

```bash
# 1. Destroy only the VM instances and disks (keeps ubuntu base image cached)
terraform destroy -target=module.control_plane -target=module.workers -auto-approve

# 2. Clean old SSH host keys from host
ssh-keygen -R 192.168.1.210 2>/dev/null; ssh-keygen -R 192.168.1.211 2>/dev/null; ssh-keygen -R 192.168.1.212 2>/dev/null; rm -f kubeconfig ~/.kube/config

# 3. Recreate VMs in ~10 seconds
terraform apply -auto-approve

# 4. Re-run bootstrap (deploys k8s, MetalLB, and Dashboard automatically)
cd ansible && source .venv/bin/activate && ansible-playbook -i inventory.ini site.yml
```

---

## 🛠️ Verification Output

```bash
$ kubectl get nodes -o wide
NAME           STATUS   ROLES           AGE   VERSION    INTERNAL-IP     OS-IMAGE             CONTAINER-RUNTIME
k8s-cp-1       Ready    control-plane   60m   v1.35.10   192.168.1.210   Ubuntu 24.04.5 LTS   containerd://2.2.1
k8s-worker-1   Ready    <none>          60m   v1.35.10   192.168.1.211   Ubuntu 24.04.5 LTS   containerd://2.2.1
k8s-worker-2   Ready    <none>          60m   v1.35.10   192.168.1.212   Ubuntu 24.04.5 LTS   containerd://2.2.1

$ kubectl get svc -n kubernetes-dashboard
NAME                   TYPE           CLUSTER-IP       EXTERNAL-IP     PORT(S)         AGE
kubernetes-dashboard   LoadBalancer   10.100.108.197   192.168.1.220   443:30443/TCP   15m
```
