# andusystems-networking

Infrastructure-as-Code repository for deploying a Kubernetes-based networking and observability cluster. Manages the full lifecycle from VM provisioning on Proxmox through Kubernetes cluster bootstrapping to application deployment, providing DNS filtering, TLS automation, and a complete LGTM (Loki, Grafana, Tempo, Mimir/Prometheus) observability stack.

## Architecture Overview

```
Proxmox Hypervisor
 └── Terraform (VM provisioning)
      └── Kubernetes Cluster (kubeadm)
           ├── MetalLB          (L2 load balancing)
           ├── Longhorn          (distributed storage)
           ├── Cert-Manager      (TLS via Let's Encrypt)
           ├── Pangolin-Newt     (VPN access)
           ├── Pi-hole           (DNS filtering)
           ├── Prometheus        (metrics)
           ├── Loki              (logs)
           ├── Tempo             (traces)
           └── Alloy             (telemetry collection)
```

The cluster runs within a dedicated network segment in a multi-segment environment. See [docs/architecture.md](docs/architecture.md) for a detailed component diagram and data-flow description.

## Quick Start

### Prerequisites

| Tool | Purpose |
|------|---------|
| Ansible | Configuration management and orchestration |
| Terraform | VM and Helm provisioning |
| `kubectl` | Kubernetes CLI |
| `helm` | Kubernetes package manager |
| SSH key pair | Passwordless access to provisioned VMs |
| Ansible Vault password | Decrypt sensitive inventory variables |

### 1. Clone and configure

```bash
git clone <repository-url>
cd andusystems-networking
```

Copy the vault example and populate it with your environment values:

```bash
cp ansible/inventory/networking/group_vars/all/vault.example \
   ansible/inventory/networking/group_vars/all/vault.yml
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault.yml
```

### 2. Install Ansible dependencies

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### 3. Deploy

**Full deployment** (VMs + Kubernetes + all applications):

```bash
./scripts/redeploy.sh
```

**Selective deployment:**

| Script | Scope |
|--------|-------|
| `scripts/vms.sh` | Provision VMs on Proxmox only |
| `scripts/kubernetes.sh` | Bootstrap Kubernetes cluster only |
| `scripts/apps.sh` | Deploy application stack only |

Each script wraps `ansible-playbook` with the correct inventory and playbook. See [docs/development.md](docs/development.md) for details.

## Deployment Scripts

All scripts are located in the `scripts/` directory and invoke `ansible-playbook` with the appropriate inventory, playbook, and tags.

### Prerequisites

Before running any script, ensure the following are in place:

- **Ansible** installed and the Galaxy dependencies from `ansible/requirements.yml` have been installed.
- **Ansible Vault password** available — the inventory references vault-encrypted variables.
- **SSH key pair** configured for passwordless access to the target VMs (required by `redeploy.sh`, `vms.sh`, and `kubernetes.sh`).
- **Proxmox API credentials** set in the vault (`proxmox_api_token_id` / `proxmox_api_token_secret`) for VM provisioning.

### `scripts/redeploy.sh`

Performs a **full end-to-end deployment**: provisions VMs, bootstraps the Kubernetes cluster, and deploys all applications in a single run.

```bash
./scripts/redeploy.sh
```

- **Playbook:** `ansible/configurations/networking.yml`
- **Tags:** `vms`, `kubernetes`, `metallb`, `apps`, `install`
- **Prompts for become password** (`-K`) — required for system-level operations on the VMs.

Use this script for first-time deployments or when you need to rebuild the entire stack from scratch.

### `scripts/vms.sh`

Provisions **VMs on Proxmox** via Terraform. This is the first stage of the deployment pipeline.

```bash
./scripts/vms.sh
```

- **Playbook:** `ansible/configurations/roles/vms.yml`
- **Tags:** `vms`
- **Prompts for become password** (`-K`).
- **Requires** Proxmox API credentials in the vault.

### `scripts/kubernetes.sh`

Bootstraps the **Kubernetes cluster** on already-provisioned VMs. Installs kubeadm, kubelet, containerd, initializes the control plane, joins worker nodes, and deploys the Flannel CNI.

```bash
./scripts/kubernetes.sh
```

- **Playbook:** `ansible/configurations/roles/kubernetes.yml`
- **Tags:** `kubernetes`, `install`
- **Prompts for become password** (`-K`) — required for package installation and cluster initialization.
- **Requires** VMs to be provisioned and reachable via SSH.

### `scripts/apps.sh`

Deploys the **application stack** (MetalLB, Longhorn, Cert-Manager, Pi-hole, observability stack, etc.) onto an existing Kubernetes cluster.

```bash
./scripts/apps.sh
```

- **Playbook:** `ansible/configurations/apps.yml`
- **Tags:** `apps`, `install`
- **Does not** prompt for a become password — application deployments run against the Kubernetes API via `kubectl`/`helm`.
- **Requires** a running Kubernetes cluster and a valid `kubeconfig`.

## Configuration Reference

All sensitive and environment-specific values are stored in Ansible Vault. The table below lists the configuration keys defined in `ansible/inventory/networking/group_vars/all/vars.yml`:

### Infrastructure

| Key | Description |
|-----|-------------|
| `ssh_user` | SSH username for VM access |
| `ssh_key_path` | Path to the SSH private key |
| `ssh_connect_timeout` | SSH connection timeout (seconds) |
| `ssh_max_retries` | Maximum SSH retry attempts |
| `ssh_retry_delay` | Delay between SSH retries (seconds) |
| `control_plane_ip` | IP address of the Kubernetes control plane node |
| `worker_ips` | List of worker node IP addresses |
| `vm_ips` | Combined list of all VM IPs |
| `kubernetes_version` | Target Kubernetes version |
| `pod_network_cidr` | CIDR range for the pod network |
| `kubeconfig` | Path to the kubeconfig file |

### Secrets & External Services

| Key | Description |
|-----|-------------|
| `cloudflare_api_token` | Cloudflare API token for DNS-01 challenges |
| `letsencrypt_email` | Email for Let's Encrypt certificate registration |
| `pangolin_endpoint` | VPN tunnel endpoint |
| `newt_id` / `newt_secret` | VPN client credentials |
| `proxmox_api_token_id` / `proxmox_api_token_secret` | Proxmox API credentials |
| `minio_root_user` / `minio_root_password` | MinIO object storage credentials |
| `grafana_admin_user` / `grafana_admin_password` | Grafana dashboard credentials |

### Application Configuration

| Key | Description |
|-----|-------------|
| `metallb_ip_range` | IP range for MetalLB LoadBalancer services |
| `homepage_url` | URL for the homepage dashboard |
| `pihole_url` | URL for the Pi-hole admin interface |

> All values are sourced from Ansible Vault (`vault_` prefixed variables). See `vault.example` for the full template.

## Repository Structure

```
.
├── ansible/
│   ├── ansible.cfg                    # Ansible configuration
│   ├── requirements.yml               # Ansible Galaxy dependencies
│   ├── configurations/
│   │   ├── networking.yml             # Infrastructure playbook
│   │   ├── apps.yml                   # Application playbook
│   │   └── roles/                     # Ansible roles
│   │       ├── vms/                   #   VM provisioning
│   │       ├── kubernetes/            #   K8s cluster setup
│   │       ├── metallb/               #   Load balancer
│   │       ├── longhorn/              #   Distributed storage
│   │       ├── cert-manager/          #   TLS automation
│   │       ├── pangolin-newt/         #   VPN
│   │       ├── pihole/               #   DNS filtering
│   │       ├── kube-prometheus-stack/ #   Metrics & alerting
│   │       ├── loki/                  #   Log aggregation
│   │       ├── tempo/                 #   Distributed tracing
│   │       └── alloy/                 #   Telemetry collectors
│   └── inventory/
│       └── networking/
│           ├── hosts.yml              # Host inventory
│           └── group_vars/all/
│               ├── vars.yml           # Variable definitions
│               └── vault.example      # Vault template
├── apps/                              # Helm values and manifests
│   ├── alloy/
│   ├── cert-manager/
│   ├── fleetdock/
│   ├── kube-prometheus-stack/
│   ├── loki/
│   ├── longhorn/
│   ├── metallb/
│   └── pangolin-newt/
├── docs/                              # Documentation
│   ├── architecture.md
│   └── development.md
└── CHANGELOG.md
```

## Ansible Roles

| Role | Purpose |
|------|---------|
| **vms** | Provision VMs on Proxmox via Terraform, configure SSH access |
| **kubernetes** | Install kubeadm/kubelet/containerd, initialize control plane, join workers, install Flannel CNI |
| **metallb** | Deploy MetalLB for L2 load balancing with a configured IP pool |
| **longhorn** | Deploy Longhorn distributed block storage as the default StorageClass |
| **cert-manager** | Install cert-manager with Let's Encrypt ACME and Cloudflare DNS-01 validation |
| **pangolin-newt** | Deploy VPN tunnel client for secure admin access |
| **pihole** | Deploy Pi-hole DNS server with ad-blocking and Traefik ingress |
| **kube-prometheus-stack** | Deploy Prometheus Operator, Prometheus, AlertManager, and node exporters |
| **loki** | Deploy Loki for log aggregation with S3-compatible storage backend |
| **tempo** | Deploy Tempo for distributed tracing with OTLP ingestion |
| **alloy** | Deploy Grafana Alloy collectors to ship metrics, logs, and traces |

## Further Documentation

- [Architecture](docs/architecture.md) - Component diagrams, data flows, and design decisions
- [Development](docs/development.md) - Local setup, prerequisites, and deployment workflows
- [Changelog](CHANGELOG.md) - Version history from git commits
