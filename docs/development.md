# Development Guide

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | 1.5+ | VM provisioning on Proxmox |
| Ansible | 2.15+ | Cluster bootstrapping and app deployment |
| kubectl | 1.31+ | Kubernetes CLI access |
| Helm | 3.x | Chart management |
| ssh-keygen / ssh-copy-id | — | SSH key distribution to nodes |

### Ansible Collection

Install the required Ansible collection:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

This installs `kubernetes.core`, used by roles that apply Kubernetes manifests.

## Local Development Setup

### 1. Clone the Repository

```bash
git clone <repository-url>
cd andusystems-networking
```

### 2. Configure Terraform Variables

Create `terraform.tfvars` files for each Terraform layer. These files are gitignored and must be created manually.

**`terraform/layers/layer-1-infrastructure/terraform.tfvars`:**

| Variable | Description |
|----------|-------------|
| `proxmox_endpoint` | Proxmox API URL |
| `proxmox_api_token` | API token for authentication |
| `proxmox_username` | Proxmox username |
| `proxmox_password` | Proxmox password |
| `proxmox_control_plane_node` | Target Proxmox node for control plane VM |
| `proxmox_worker_nodes` | List of Proxmox nodes for worker VMs |
| `control_plane_ip` | Static IP for the control plane |
| `worker_ips` | List of static IPs for worker nodes |
| `network_gateway` | Default gateway IP |
| `network_prefix` | Network prefix length (e.g., 24) |
| `ssh_public_key` | Public key for cloud-init |
| `ssh_private_key` | Private key path for provisioning |
| `ubuntu_cloud_image_url` | Ubuntu cloud image download URL |
| `cluster_name` | Name prefix for VMs |

**`terraform/layers/layer-2-helmapps/terraform.tfvars`:**

| Variable | Description |
|----------|-------------|
| `kubeconfig_path` | Path to the cluster kubeconfig |

### 3. Configure Ansible Vault

Create the vault file from the provided example:

```bash
cp ansible/inventory/networking/group_vars/all/vault.example \
   ansible/inventory/networking/group_vars/all/vault
```

Edit the vault file to populate all required secrets. Key variables:

| Variable | Description |
|----------|-------------|
| `ssh_user` | SSH username for node access |
| `ssh_key_path` | Path to SSH private key |
| `kubernetes_version` | Target Kubernetes version (e.g., `1.31`) |
| `pod_network_cidr` | Pod network CIDR for Flannel |
| `metallb_ip_range` | IP range for MetalLB pool |
| `networking_traefik_server_ip` | Traefik LoadBalancer IP |
| `cloudflare_api_token` | Cloudflare API token for DNS-01 |
| `letsencrypt_email` | Email for Let's Encrypt registration |
| `pangolin_endpoint` | Pangolin VPN endpoint |
| `newt_id` | Newt tunnel identity |
| `newt_secret` | Newt tunnel secret |
| `pihole_url` | Pi-hole ingress hostname |
| `grafana_admin_user` | Grafana admin username |
| `grafana_admin_password` | Grafana admin password |
| `minio_root_user` | MinIO root username |
| `minio_root_password` | MinIO root password |
| `proxmox_api_token_id` | Proxmox API token ID |
| `proxmox_api_token_secret` | Proxmox API token secret |

Encrypt the vault:

```bash
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault
```

### 4. Ansible Configuration

The Ansible configuration (`ansible/ansible.cfg`) disables host key checking and logs to `ansible.log`:

```ini
[defaults]
host_key_checking = False
log_path = ansible.log
```

No additional Ansible configuration is needed.

## Build / Deploy Commands

### Full Infrastructure Deployment

Deploy everything from VMs through applications:

```bash
./scripts/redeploy.sh
```

This runs: VM provisioning → Kubernetes bootstrap → MetalLB → All applications.

### Individual Steps

| Step | Command | Requires `-K` |
|------|---------|---------------|
| Provision VMs | `./scripts/vms.sh` | Yes |
| Bootstrap Kubernetes | `./scripts/kubernetes.sh` | Yes |
| Deploy applications | `./scripts/apps.sh` | No |
| Full redeploy | `./scripts/redeploy.sh` | Yes |

The `-K` flag prompts for the Ansible become (sudo) password on target hosts. Application deployment does not require sudo because it runs `kubectl`/`helm` commands against the Kubernetes API.

### Running Individual Roles

To deploy a single component:

```bash
ansible-playbook \
  -i ansible/inventory/networking \
  ansible/configurations/roles/<role>.yml \
  --tags <role>,install
```

Replace `<role>` with one of: `vms`, `kubernetes`, `metallb`, `longhorn`, `cert-manager`, `pangolin-newt`, `traefik`, `pihole`, `loki`, `tempo`.

### Terraform Operations

Terraform is invoked automatically by the `vms` and `metallb` Ansible roles. For manual operations:

```bash
# Layer 1 — VM infrastructure
cd terraform/layers/layer-1-infrastructure
terraform init
terraform plan
terraform apply

# Layer 2 — MetalLB Helm chart
cd terraform/layers/layer-2-helmapps
terraform init
terraform plan
terraform apply
```

## Environment Variables

No environment variables are required. All configuration is provided through:

- **Terraform:** `terraform.tfvars` files in each layer directory
- **Ansible:** Vault-encrypted variables in `ansible/inventory/networking/group_vars/all/vault`

## Playbook Execution Order

The full `networking.yml` playbook imports roles in this order:

1. `vms` — Provision Proxmox VMs, distribute SSH keys
2. `kubernetes` — Install containerd, kubeadm, initialize cluster, join workers, deploy Flannel CNI
3. `metallb` — Deploy MetalLB via Terraform layer-2, configure IP address pool
4. `longhorn` — Deploy Longhorn distributed storage
5. `cert-manager` — Install CRDs, deploy cert-manager, create ClusterIssuer
6. `pangolin-newt` — Deploy Newt VPN tunnel
7. `traefik` — Deploy Traefik ingress controller with LoadBalancer
8. `pihole` — Deploy Pi-hole DNS with IngressRoute

The `apps.yml` playbook skips VM provisioning and Kubernetes bootstrap, starting from `longhorn`.

## Testing

There are no automated tests. Validation is manual:

```bash
# Verify all nodes are Ready
kubectl --kubeconfig kubeconfig get nodes

# Verify all pods are Running
kubectl --kubeconfig kubeconfig get pods -A

# Verify LoadBalancer IPs are assigned
kubectl --kubeconfig kubeconfig get svc -A | grep LoadBalancer

# Verify certificates are issued
kubectl --kubeconfig kubeconfig get certificates -A
```

## Troubleshooting

### Ansible Connection Failures

Check that SSH keys were distributed correctly:

```bash
ssh -i <key-path> <user>@<control-plane-ip>
```

Ansible logs are written to `ansible.log` in the repository root.

### Terraform State Issues

Terraform state is stored locally in each layer directory. If state becomes corrupted:

```bash
cd terraform/layers/layer-1-infrastructure
terraform refresh
```

State files (`*.tfstate`) are gitignored.

### Kubernetes Join Failures

If workers fail to join, the join token may have expired. Re-run the kubernetes role:

```bash
./scripts/kubernetes.sh
```

The role regenerates the join command from the control plane on each run.
