# Method of Procedure (MOP)
## Production Deployment, Operation & Teardown Guide

This document is the operational Method of Procedure (MOP) for provisioning, configuring, verifying, maintaining, and tearing down the 3-node Kubernetes cluster on KVM/libvirt.

---

## 1. Document Overview

- **Project:** `k8s-terraform`
- **Environment:** Local Ubuntu KVM/libvirt Host (Bridged LAN: `192.168.1.0/24`)
- **Node Allocations:**
  - Control Plane: `k8s-cp-1` (`192.168.1.210`) - 2 vCPU, 4096 MiB RAM, 20 GiB disk
  - Worker 1: `k8s-worker-1` (`192.168.1.211`) - 2 vCPU, 2048 MiB RAM, 20 GiB disk
  - Worker 2: `k8s-worker-2` (`192.168.1.212`) - 2 vCPU, 2048 MiB RAM, 20 GiB disk
- **Pod Network CIDR:** `10.244.0.0/16` (Flannel CNI)
- **Kubernetes Version:** `v1.35.10`

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

kubectl get nodes -o wide
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
