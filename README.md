# andusystems-networking

> Infrastructure-as-Code for the networking cluster — Kubernetes-based ingress, DNS, TLS, observability, and storage for the andusystems homelab.

## Purpose

This repository defines the networking cluster: a dedicated Kubernetes cluster that handles ingress routing, DNS filtering, TLS certificate automation, load balancing, VPN tunneling, distributed storage, and full-stack observability for a multi-cluster homelab. The cluster is provisioned on a Proxmox hypervisor via Terraform, bootstrapped with Ansible, and managed through GitOps by a central ArgoCD instance on the management cluster. All secrets are vault-encrypted; no plaintext credentials exist in the repository.

## At a glance

| Field | Value |
|---|---|
| Type | IaC cluster |
| Role | spoke — networking services hub for other clusters |
| Primary stack | Terraform + Ansible + ArgoCD |
| Deployed by | hub ArgoCD (Helm apps) / Ansible (infra bootstrap) |
| Status | production |

## Components

| Component | Purpose | Location |
|---|---|---|
| Traefik | Reverse proxy ingress with TLS termination | `apps/traefik/` |
| Pi-hole | DNS resolver with ad-blocking (19 curated blocklists) | `apps/pihole/` |
| MetalLB | Layer 2 load balancer for bare-metal LoadBalancer services | `apps/metallb/` |
| cert-manager | Let's Encrypt TLS automation via Cloudflare DNS-01 | `apps/cert-manager/` |
| Pangolin / Newt | VPN tunnel for secure remote cluster access | `apps/pangolin-newt/` |
| Longhorn | Distributed block storage, 3-replica default | `apps/longhorn/` |
| Loki | Log aggregation, SingleBinary mode, S3 backend, 30-day retention | `apps/loki/` |
| Tempo | Distributed tracing, OTLP receiver, S3 backend | `apps/tempo/` |
| Prometheus | Metrics collection, 7-day retention, AlertManager | `apps/kube-prometheus-stack/` |
| Alloy | Telemetry collector — metrics, logs, traces (deployed by hub) | `apps/alloy/` |
| cluster-status | Nginx healthz endpoint with TLS for uptime monitoring | `apps/cluster-status/` |

## Architecture

```
External Client
      │
      ▼
┌──────────────────┐
│  Pangolin / Newt │  VPN entry point
└────────┬─────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│                  Networking Cluster                  │
│                                                      │
│  MetalLB (L2) — assigns LoadBalancer IPs from pool  │
│          │                                           │
│   ┌──────┴────┐  ┌──────────┐  ┌───────────────┐   │
│   │  Traefik  │  │ Pi-hole  │  │  cert-manager │   │
│   │ (Ingress) │  │  (DNS)   │  │  (TLS / ACME) │   │
│   └───────────┘  └──────────┘  └───────────────┘   │
│                                                      │
│   ┌──────────────────────────────────────────────┐  │
│   │              Observability Stack             │  │
│   │   Alloy ──► Loki / Tempo / Prometheus        │  │
│   └──────────────────────────────────────────────┘  │
│                                                      │
│   ┌──────────────────────────────────────────────┐  │
│   │   Longhorn (distributed block storage)       │  │
│   └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
         │
         ▼
   External S3 (Loki + Tempo long-term retention)
```

Traffic enters through the Pangolin/Newt VPN tunnel and routes to Traefik (via a MetalLB LoadBalancer IP); cert-manager automates TLS certificates using Cloudflare DNS-01 challenges. See [docs/architecture.md](docs/architecture.md) for full component diagrams and data flows.

## Quick start

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | 1.5+ | VM provisioning on Proxmox |
| Ansible | 2.15+ | Cluster bootstrap and app deployment |
| kubectl | 1.31+ | Kubernetes API access |
| Helm | 3.x | Chart management (invoked by Ansible roles) |

### Deploy / run

```bash
# Install required Ansible collections
ansible-galaxy collection install -r ansible/requirements.yml

# Provision VMs on Proxmox (prompts for sudo password on target hosts)
./scripts/vms.sh

# Bootstrap Kubernetes cluster (prompts for sudo password on target hosts)
./scripts/kubernetes.sh

# Deploy all applications
./scripts/apps.sh
```

Run the entire pipeline in one command:

```bash
./scripts/redeploy.sh
```

See [docs/development.md](docs/development.md) for vault setup, Terraform variable configuration, and individual role deployment.

## Configuration

All secrets are stored in an Ansible vault file at `ansible/inventory/networking/group_vars/all/vault`. Copy `vault.example` in the same directory to get the full list of required keys. Values reference encrypted vault variables in `vars.yml`.

| Key | Required | Description |
|---|---|---|
| `ssh_user` | Yes | SSH username for node access |
| `ssh_key_path` | Yes | Path to SSH private key |
| `kubernetes_version` | Yes | Target Kubernetes version |
| `pod_network_cidr` | Yes | Pod CIDR for Flannel CNI |
| `metallb_ip_range` | Yes | IP range for MetalLB LoadBalancer pool |
| `networking_traefik_server_ip` | Yes | Traefik LoadBalancer IP |
| `cloudflare_api_token` | Yes | Cloudflare API token for DNS-01 challenges |
| `letsencrypt_email` | Yes | Email for Let's Encrypt ACME registration |
| `pangolin_endpoint` | Yes | Pangolin VPN endpoint address |
| `newt_id` | Yes | Newt tunnel identity |
| `newt_secret` | Yes | Newt tunnel secret |
| `minio_root_user` | Yes | MinIO S3 backend username |
| `minio_root_password` | Yes | MinIO S3 backend password |
| `proxmox_api_token_id` | Yes | Proxmox API token ID |
| `proxmox_api_token_secret` | Yes | Proxmox API token secret |
| `grafana_admin_user` | Yes | Grafana admin username (hub Grafana) |
| `grafana_admin_password` | Yes | Grafana admin password (hub Grafana) |

## Repository layout

```
.
├── terraform/
│   └── layers/
│       ├── layer-1-infrastructure/   # Proxmox VM provisioning (control plane + workers)
│       └── layer-2-helmapps/         # MetalLB Helm deployment
├── ansible/
│   ├── ansible.cfg                   # Ansible defaults (SSH, logging)
│   ├── requirements.yml              # Galaxy collection dependencies
│   ├── inventory/networking/         # Hosts and vault-encrypted variables
│   └── configurations/
│       ├── networking.yml            # Full-stack playbook (VMs → apps)
│       ├── apps.yml                  # Apps-only playbook (skips infra)
│       └── roles/                    # One role per cluster component
├── apps/                             # Helm values and Kubernetes manifests
│   ├── cert-manager/                 # ClusterIssuer manifest + Helm values
│   ├── cluster-status/               # Healthz endpoint manifest
│   ├── kube-prometheus-stack/        # Prometheus + AlertManager Helm values
│   ├── loki/  tempo/  alloy/         # Observability stack
│   ├── longhorn/  metallb/           # Storage and load balancer
│   ├── pangolin-newt/                # VPN tunnel manifest
│   └── pihole/  traefik/             # DNS and ingress
├── scripts/                          # vms.sh  kubernetes.sh  apps.sh  redeploy.sh
└── docs/                             # Architecture and development guides
```

## Related repos

| Repo | Relation |
|---|---|
| andusystems-management | hub — manages Traefik and other ArgoCD-deployed apps on this cluster |

## Further documentation

- [Architecture](docs/architecture.md) — component diagrams, data flows, design decisions
- [Development](docs/development.md) — local setup, prerequisites, deployment commands
- [Changelog](CHANGELOG.md) — release history
