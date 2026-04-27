# Development Guide

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | 1.5+ | VM provisioning on Proxmox |
| Ansible | 2.15+ | Cluster bootstrapping and app deployment |
| kubectl | 1.31+ | Kubernetes CLI access |
| Helm | 3.x | Chart management (invoked by Ansible roles) |
| ssh-keygen / ssh-copy-id | — | SSH key distribution to nodes |

### Ansible Collection

Install the required Ansible collection before running any playbook:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

This installs `kubernetes.core`, used by roles that apply Kubernetes manifests and wait for resource availability.

## Local Development Setup

### 1. Clone the Repository

```bash
git clone <repository-url>
cd andusystems-networking
```

### 2. Configure Terraform Variables

Create `terraform.tfvars` files for each Terraform layer. These files are gitignored and must be created manually before running any script that invokes Terraform.

**`terraform/layers/layer-1-infrastructure/terraform.tfvars`:**

| Variable | Description |
|----------|-------------|
| `proxmox_endpoint` | Proxmox API URL |
| `proxmox_api_token` | API token for Proxmox authentication |
| `proxmox_username` | Proxmox username |
| `proxmox_password` | Proxmox password |
| `proxmox_control_plane_node` | Target Proxmox node for the control plane VM |
| `proxmox_worker_nodes` | List of Proxmox nodes for worker VMs |
| `control_plane_ip` | Static IP for the control plane |
| `worker_ips` | List of static IPs for worker nodes |
| `network_gateway` | Default gateway IP |
| `network_prefix` | Network prefix length (e.g., `24`) |
| `ssh_public_key` | Public key injected via cloud-init |
| `ssh_private_key` | Private key path used during provisioning |
| `ubuntu_cloud_image_url` | Ubuntu cloud image download URL |
| `cluster_name` | Name prefix applied to all VMs |

**`terraform/layers/layer-2-helmapps/terraform.tfvars`:**

| Variable | Description |
|----------|-------------|
| `kubeconfig_path` | Path to the cluster kubeconfig (fetched by the Kubernetes role) |

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
| `pod_network_cidr` | Pod network CIDR for Flannel (e.g., `10.244.0.0/16`) |
| `metallb_ip_range` | IP range for the MetalLB LoadBalancer pool |
| `networking_traefik_server_ip` | Traefik LoadBalancer IP |
| `cloudflare_api_token` | Cloudflare API token for DNS-01 challenges |
| `letsencrypt_email` | Email for Let's Encrypt ACME registration |
| `pangolin_endpoint` | Pangolin VPN endpoint |
| `newt_id` | Newt tunnel identity |
| `newt_secret` | Newt tunnel secret |
| `pihole_url` | Pi-hole ingress hostname |
| `grafana_admin_user` | Grafana admin username |
| `grafana_admin_password` | Grafana admin password |
| `minio_root_user` | MinIO S3 backend username |
| `minio_root_password` | MinIO S3 backend password |
| `proxmox_api_token_id` | Proxmox API token ID |
| `proxmox_api_token_secret` | Proxmox API token secret |

Encrypt the vault file before committing or sharing:

```bash
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault
```

When running playbooks against an encrypted vault, pass `--ask-vault-pass` or configure a vault password file.

### 4. Ansible Configuration

The Ansible configuration at `ansible/ansible.cfg` disables host key checking and logs to `ansible.log` in the repository root:

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

This runs: VM provisioning → Kubernetes bootstrap → MetalLB → all applications.

### Individual Steps

| Step | Command | Requires `-K` |
|------|---------|---------------|
| Provision VMs | `./scripts/vms.sh` | Yes |
| Bootstrap Kubernetes | `./scripts/kubernetes.sh` | Yes |
| Deploy applications | `./scripts/apps.sh` | No |
| Full redeploy | `./scripts/redeploy.sh` | Yes |

The `-K` flag prompts for the Ansible become (sudo) password on target hosts. Application deployment does not require sudo because it runs `kubectl` and `helm` commands against the Kubernetes API.

### Running Individual Roles

To deploy or redeploy a single component:

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

No environment variables are required at the shell level. All configuration is provided through:

- **Terraform:** `terraform.tfvars` files in each layer directory.
- **Ansible:** Vault-encrypted variables in `ansible/inventory/networking/group_vars/all/vault`.

## Playbook Execution Order

The full `networking.yml` playbook imports roles in this order:

| Step | Role | What it does |
|------|------|--------------|
| 1 | `vms` | Provision Proxmox VMs, distribute SSH keys, configure `/etc/hosts` |
| 2 | `kubernetes` | Install containerd + kubeadm, initialize cluster, join workers, deploy Flannel CNI |
| 3 | `metallb` | Deploy MetalLB via Terraform layer-2, configure IP address pool |
| 4 | `longhorn` | Deploy Longhorn distributed storage |
| 5 | `cert-manager` | Install CRDs, deploy cert-manager, create ClusterIssuer (DNS-01) |
| 6 | `pangolin-newt` | Deploy Newt VPN tunnel with vault-templated credentials |
| 7 | `traefik` | No-op role; Traefik is deployed by the hub ArgoCD instance |
| 8 | `loki` | Create namespace, apply MinIO secret, deploy Loki (SingleBinary) |
| 9 | `tempo` | Create namespace, apply MinIO secret, deploy Tempo (SingleBinary) |
| 10 | `pihole` | Create namespace, apply IngressRoute and Certificate manifests |

The `apps.yml` playbook skips VM provisioning and Kubernetes bootstrap, starting from `longhorn`. Alloy is excluded from `apps.yml` — it is deployed and managed by the hub cluster's ArgoCD instance.

## ArgoCD-Managed Components

Two components in this repository are deployed by the management cluster's ArgoCD rather than by local Ansible:

| Component | Reason |
|-----------|--------|
| Traefik | Managed centrally to keep ingress controller versions consistent across clusters |
| Alloy | Deployed as part of the hub's observability rollout across all clusters |

The Helm values files in `apps/traefik/` and `apps/alloy/` are still maintained here and referenced by the hub ArgoCD application definitions.

## Testing

There are no automated tests. Validation is manual after each deployment step:

```bash
# Verify all nodes are Ready
kubectl --kubeconfig kubeconfig get nodes

# Verify all pods are Running
kubectl --kubeconfig kubeconfig get pods -A

# Verify LoadBalancer IPs are assigned
kubectl --kubeconfig kubeconfig get svc -A | grep LoadBalancer

# Verify TLS certificates are issued
kubectl --kubeconfig kubeconfig get certificates -A

# Check the cluster-status healthz endpoint
curl https://<status-hostname>/healthz
```

## Troubleshooting

### Ansible Connection Failures

Verify that SSH keys were distributed correctly by the `vms` role:

```bash
ssh -i <key-path> <ssh_user>@<control-plane-ip>
```

Ansible writes a full log to `ansible.log` in the repository root.

### Terraform State Issues

Terraform state is stored locally in each layer directory. If state becomes inconsistent with actual resources:

```bash
cd terraform/layers/layer-1-infrastructure
terraform refresh
```

State files (`*.tfstate`) are gitignored and must not be committed.

### Kubernetes Join Failures

If workers fail to join, the bootstrap token may have expired (tokens expire after 24 hours by default). Re-run the kubernetes role to regenerate the join command:

```bash
./scripts/kubernetes.sh
```

The role fetches a fresh join command from the control plane on every run.

### cert-manager ClusterIssuer Not Ready

The cert-manager role waits up to 5 minutes (30 retries × 10 seconds) for the ClusterIssuer CRD to register before applying the ClusterIssuer manifest. If the wait times out, check cert-manager pod logs:

```bash
kubectl --kubeconfig kubeconfig logs -n cert-manager \
  -l app.kubernetes.io/name=cert-manager
```
