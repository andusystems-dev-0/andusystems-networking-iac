# Development Guide

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Ansible | 2.15+ | Orchestration and configuration management |
| Terraform | 1.5+ | VM provisioning and Helm deployment |
| kubectl | Matching cluster version | Kubernetes CLI |
| Helm | 3.x | Kubernetes package manager |
| Python 3 | 3.10+ | Required by Ansible |
| `kubernetes` Python package | Latest | Required by `kubernetes.core` Ansible collection |
| SSH client | Any | Access to provisioned VMs |

### Ansible Collections

Install required Ansible collections:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

This installs:
- `kubernetes.core` - provides `k8s` module for applying Kubernetes manifests

## Environment Setup

### 1. Ansible Vault

All secrets are managed via Ansible Vault. Create and encrypt your vault file:

```bash
cp ansible/inventory/networking/group_vars/all/vault.example \
   ansible/inventory/networking/group_vars/all/vault.yml
```

Edit `vault.yml` with your environment values, then encrypt:

```bash
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault.yml
```

To edit an encrypted vault:

```bash
ansible-vault edit ansible/inventory/networking/group_vars/all/vault.yml
```

### 2. Terraform Variables

Terraform is invoked by Ansible roles (notably `vms` and `metallb`). Terraform variable files (`.tfvars`) should be configured and their path set in the vault as `repo_root` and `tfvars_file`.

### 3. SSH Keys

Ensure an SSH key pair exists and the public key path is configured in the Terraform variables. The `vms` role uses `ssh-copy-id` to establish passwordless access to all provisioned VMs.

### 4. Kubeconfig

After cluster bootstrapping, the `kubernetes` role fetches the kubeconfig to your local machine. The path is configured via the `kubeconfig` vault variable and used by subsequent roles to interact with the cluster.

## Deployment Commands

### Full Stack Deployment

Provisions VMs, bootstraps Kubernetes, and deploys all applications:

```bash
./scripts/redeploy.sh
```

### Infrastructure Only

Provision VMs on Proxmox:

```bash
./scripts/vms.sh
```

### Kubernetes Only

Bootstrap the Kubernetes cluster (assumes VMs are already provisioned):

```bash
./scripts/kubernetes.sh
```

### Applications Only

Deploy all platform services (assumes a running Kubernetes cluster):

```bash
./scripts/apps.sh
```

### Running Playbooks Directly

For more granular control, run Ansible playbooks directly:

```bash
# Full infrastructure + networking stack
ansible-playbook ansible/configurations/networking.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass

# Applications only
ansible-playbook ansible/configurations/apps.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

### Running a Single Role

To deploy a single component, limit the playbook run with tags or by running the role playbook directly. Each role has a top-level playbook (e.g., `ansible/configurations/roles/loki.yml`) that can be imported or used as reference.

## Playbook Structure

### networking.yml (Infrastructure Playbook)

Executes in order:

1. **vms** - Provision VMs on Proxmox via Terraform
2. **kubernetes** - Install and initialize the Kubernetes cluster
3. **metallb** - Deploy MetalLB L2 load balancer
4. **longhorn** - Deploy distributed storage
5. **cert-manager** - Deploy TLS certificate automation
6. **pangolin-newt** - Deploy VPN tunnel
7. **pihole** - Deploy DNS filtering

### apps.yml (Application Playbook)

Executes in order:

1. **longhorn** - Distributed storage
2. **cert-manager** - TLS automation
3. **pangolin-newt** - VPN
4. **kube-prometheus-stack** - Prometheus, AlertManager, node exporters
5. **loki** - Log aggregation
6. **tempo** - Distributed tracing
7. **alloy** - Telemetry collectors
8. **pihole** - DNS filtering

## Ansible Role Structure

Each role follows a consistent layout:

```
roles/<name>/
├── defaults/
│   └── main.yml     # Default variables (optional)
├── tasks/
│   ├── main.yml     # Task entry point
│   └── install.yml  # Installation tasks
└── <name>.yml       # Role-level playbook wrapper
```

The role-level playbook (e.g., `roles/loki.yml`) sets the target hosts and invokes the role via `include_role`.

## Helm Values and Manifests

Application configuration is split between two file types in the `apps/` directory:

| File | Purpose |
|------|---------|
| `values.yml` | Helm chart value overrides |
| `manifest.yml` | Raw Kubernetes manifests (Secrets, CRDs, IngressRoutes) applied via `kubernetes.core.k8s` |

Manifests use Jinja2 templating (`{{ variable }}`) and are rendered by Ansible at deploy time, enabling secret injection from the vault without committing sensitive values.

## Configuration Patterns

### Secret Injection

Secrets flow through the system as follows:

```
Ansible Vault (encrypted)
  └── group_vars/all/vars.yml (references vault_ variables)
       └── Ansible tasks (inject into manifests/Helm values)
            └── Kubernetes Secrets (created via manifest.yml)
```

Sensitive tasks use `no_log: true` to prevent secrets from appearing in Ansible output.

### StorageClass

All stateful applications use the `longhorn` StorageClass for persistent volumes. Longhorn is configured as the default StorageClass cluster-wide.

### LoadBalancer Services

Services requiring external access use `type: LoadBalancer` with fixed IP assignments from the MetalLB IP pool. The IP range is configured via the `metallb_ip_range` vault variable.

## Modifying an Existing Application

1. Edit the Helm values in `apps/<name>/values.yml`
2. If Kubernetes manifests need changes, edit `apps/<name>/manifest.yml`
3. Run the application playbook:
   ```bash
   ./scripts/apps.sh
   ```

## Adding a New Application

1. Create `apps/<name>/values.yml` with Helm value overrides
2. Optionally create `apps/<name>/manifest.yml` for additional Kubernetes resources
3. Create the Ansible role structure under `ansible/configurations/roles/<name>/`
4. Add the role import to `ansible/configurations/apps.yml`
5. Add any required vault variables to `group_vars/all/vars.yml`
6. Run the deployment

## Troubleshooting

### Vault Password

If deployment fails with a vault decryption error, ensure you are providing the correct vault password. Use `--ask-vault-pass` or set `ANSIBLE_VAULT_PASSWORD_FILE`.

### Kubernetes Connectivity

If roles that apply Kubernetes manifests fail, verify:
- The kubeconfig path in vault is correct
- The cluster is reachable from the Ansible control node
- The kubeconfig has been fetched (run the `kubernetes` role first)

### Helm Chart Failures

If a Helm deployment fails, check:
- Network connectivity from the cluster to Helm chart repositories
- That CRDs are installed before the chart that depends on them (the playbook ordering handles this)
- Available storage (Longhorn must be healthy before deploying stateful apps)
