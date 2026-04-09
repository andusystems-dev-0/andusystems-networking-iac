# Development Guide

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Ansible | 2.15+ | `pip install ansible` |
| Terraform | 1.5+ | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| kubectl | 1.31+ | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Python | 3.10+ | System package manager |
| ansible-vault | (bundled) | Included with Ansible |
| Helm | 3.x | [helm.sh](https://helm.sh/docs/intro/install/) |

## Initial Setup

### 1. Clone the Repository

```bash
git clone <repository-url>
cd andusystems-networking
```

### 2. Install Ansible Collections

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

This installs the `kubernetes.core` collection required for Kubernetes module operations.

### 3. Configure Secrets

```bash
cp ansible/inventory/networking/group_vars/all/vault.example \
   ansible/inventory/networking/group_vars/all/vault.yml
```

Edit `vault.yml` with your environment values, then encrypt:

```bash
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault.yml
```

To edit later:

```bash
ansible-vault edit ansible/inventory/networking/group_vars/all/vault.yml
```

See the [Configuration Reference](../README.md#configuration-reference) in the README for all required vault variables.

### 4. Verify Connectivity

Ensure SSH access to all target nodes:

```bash
ansible all -i ansible/inventory/networking/hosts.yml -m ping --ask-vault-pass
```

## Deployment Workflows

### Full Infrastructure Deployment

Provisions VMs, bootstraps Kubernetes, and installs all base networking components:

```bash
ansible-playbook ansible/configurations/networking.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

**Execution order:** VMs → Kubernetes → MetalLB → Longhorn → Cert-Manager → Pangolin-Newt → Pi-hole

### Application Stack Deployment

Deploys the observability stack and application services. Requires the base infrastructure to be running:

```bash
ansible-playbook ansible/configurations/apps.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

**Execution order:** Longhorn → Cert-Manager → Pangolin-Newt → Kube-Prometheus-Stack → Loki → Tempo → Alloy → Pi-hole

### Running a Single Role

To deploy or update a specific component, run its role directly:

```bash
ansible-playbook ansible/configurations/roles/<role-name>.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

For example, to redeploy only Pi-hole:

```bash
ansible-playbook ansible/configurations/roles/pihole.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

### Targeting Specific Hosts

Use `--limit` to restrict execution to specific inventory groups:

```bash
# Only run on worker nodes
ansible-playbook ansible/configurations/networking.yml \
  -i ansible/inventory/networking/hosts.yml \
  --limit workers \
  --ask-vault-pass

# Only run on the control plane
ansible-playbook ansible/configurations/networking.yml \
  -i ansible/inventory/networking/hosts.yml \
  --limit controllers \
  --ask-vault-pass
```

## Environment Variables

Ansible behavior is configured through `ansible/ansible.cfg`:

| Setting | Value | Description |
|---------|-------|-------------|
| `host_key_checking` | `False` | Disables SSH host key verification (VMs are frequently reprovisioned) |
| `log_path` | `ansible.log` | All Ansible output is logged to this file |

Additional environment variables can be set as needed:

| Variable | Description |
|----------|-------------|
| `ANSIBLE_VAULT_PASSWORD_FILE` | Path to a file containing the vault password (avoids `--ask-vault-pass`) |
| `ANSIBLE_CONFIG` | Override path to `ansible.cfg` |
| `KUBECONFIG` | Path to cluster kubeconfig (set automatically after Kubernetes role runs) |

## Project Structure

### Ansible Roles

Each role follows the same structure:

```
roles/<component>/
  ├── tasks/
  │   ├── main.yml      # Entry point (imports install.yml)
  │   └── install.yml   # Installation logic
  └── defaults/
      └── main.yml      # Default variables (if any)
```

Role wrapper playbooks live at `roles/<component>.yml` and set the target hosts and import the role.

### Application Configuration

Helm values and Kubernetes manifests live under `apps/<component>/`:

```
apps/<component>/
  ├── values.yml       # Helm chart values
  └── manifest.yml     # Raw Kubernetes manifests (Secrets, CRDs, etc.)
```

Manifests may contain Jinja2 templates (e.g. `{{ metallb_ip_range }}`) that are rendered by Ansible at apply time.

### Inventory

```
ansible/inventory/networking/
  ├── hosts.yml                    # Node definitions (controllers, workers)
  └── group_vars/all/
      ├── vars.yml                 # Variable mapping (vault → playbook vars)
      └── vault.example            # Template for vault secrets
```

The `hosts.yml` file defines node groups: `controllers` (single control-plane node) and `workers` (multiple worker nodes). All host IPs are sourced from vault variables.

## Modifying Helm Values

To change the configuration of a deployed component:

1. Edit the relevant `apps/<component>/values.yml` file
2. Re-run the component's role or the full `apps.yml` playbook
3. The role applies the updated Helm values via Terraform or `kubectl apply`

### Key Helm Chart Sources

| Component | Chart | Repository |
|-----------|-------|------------|
| Longhorn | `longhorn/longhorn` | Longhorn Helm repo |
| Cert-Manager | `jetstack/cert-manager` | Jetstack Helm repo |
| MetalLB | `metallb/metallb` | MetalLB Helm repo |
| Kube-Prometheus-Stack | `prometheus-community/kube-prometheus-stack` | Prometheus Community |
| Loki | `grafana/loki` | Grafana Helm repo |
| Tempo | `grafana/tempo` | Grafana Helm repo |
| Alloy | `grafana/k8s-monitoring` | Grafana Helm repo |
| Traefik | `traefik/traefik` | Traefik Helm repo |
| Pi-hole | `mojo2600/pihole` | Pi-hole Helm repo |

## Adding a New Component

1. Create the Helm values file at `apps/<component>/values.yml`
2. If raw manifests are needed, create `apps/<component>/manifest.yml`
3. Create the Ansible role under `ansible/configurations/roles/<component>/`
   - `tasks/main.yml` -- import install tasks
   - `tasks/install.yml` -- namespace creation, CRD installation, manifest application
4. Create the role wrapper playbook at `ansible/configurations/roles/<component>.yml`
5. Add the role import to `ansible/configurations/apps.yml` (or `networking.yml` for infrastructure components)

## Troubleshooting

### Ansible Connection Failures

The VMs role configures SSH keys and known_hosts entries. If connections fail after reprovisioning:

```bash
# Clear stale SSH keys for a host
ssh-keygen -R <hostname>
# Re-run the VMs role to refresh keys
ansible-playbook ansible/configurations/roles/vms.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

### Kubernetes Join Failures

Worker join is retried 3 times with a 15-second delay. If workers fail to join:

```bash
# Check control plane status
kubectl get nodes
# View join token
kubeadm token list
# Re-run the Kubernetes role
ansible-playbook ansible/configurations/roles/kubernetes.yml \
  -i ansible/inventory/networking/hosts.yml \
  --ask-vault-pass
```

### CRD Registration Delays

Roles that install CRDs (cert-manager, kube-prometheus-stack) include wait loops (30 retries, 10-second delay). If a CRD fails to register, check:

```bash
kubectl get crd | grep <component>
kubectl describe crd <crd-name>
```

### Checking Logs

Ansible logs all output to `ansible.log` in the repository root. Review it for detailed error output from failed tasks.
