# andusystems-networking

Infrastructure-as-Code repository for the **networking cluster** — a Kubernetes cluster dedicated to ingress routing, DNS, TLS certificate management, and observability collection within a multi-cluster homelab environment.

## Purpose

This cluster serves as the networking backbone for public-facing application traffic. It provides:

- **Ingress** — Traefik reverse proxy with TLS termination
- **DNS** — Pi-hole for ad-blocking DNS resolution with upstream forwarding
- **Load Balancing** — MetalLB for bare-metal LoadBalancer services
- **TLS** — cert-manager with Let's Encrypt (DNS-01 via Cloudflare)
- **VPN** — Pangolin/Newt tunnel for secure remote access
- **Storage** — Longhorn distributed block storage
- **Observability** — Prometheus, Loki, Tempo, and Alloy for metrics, logs, and traces

The cluster is managed via GitOps from a central ArgoCD instance on a separate management cluster.

## Architecture Summary

```
                          External Traffic
                               │
                               ▼
                    ┌─────────────────────┐
                    │   Pangolin / Newt   │
                    │    (VPN Tunnel)     │
                    └─────────┬───────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Networking Cluster                            │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │                      MetalLB (L2)                          │    │
│  │              Assigns LoadBalancer IPs from pool             │    │
│  └────────────────────┬───────────────────────────────────────┘    │
│                       │                                             │
│         ┌─────────────┼─────────────┬──────────────┐               │
│         ▼             ▼             ▼              ▼               │
│  ┌───────────┐ ┌───────────┐ ┌──────────┐ ┌────────────┐         │
│  │  Traefik  │ │  Pi-hole  │ │   Loki   │ │ Prometheus │         │
│  │  (Ingress)│ │   (DNS)   │ │  (Logs)  │ │ (Metrics)  │         │
│  └─────┬─────┘ └───────────┘ └────┬─────┘ └──────┬─────┘         │
│        │                          │               │                │
│        │         ┌────────────────┼───────────────┤                │
│        │         │                │               │                │
│        │    ┌────┴─────┐   ┌─────┴────┐   ┌─────┴──────┐         │
│        │    │  Tempo   │   │  Alloy   │   │ AlertMgr   │         │
│        │    │ (Traces) │   │(Collect) │   │ (Alerts)   │         │
│        │    └──────────┘   └──────────┘   └────────────┘         │
│        │                                                          │
│  ┌─────┴──────────────────────────────────────────────────┐      │
│  │                   cert-manager                          │      │
│  │         Let's Encrypt DNS-01 via Cloudflare             │      │
│  └─────────────────────────────────────────────────────────┘      │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                     Longhorn                              │      │
│  │            Distributed block storage (3 replicas)         │      │
│  └──────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  External S3 Store  │
                    │  (Loki + Tempo      │
                    │   long-term data)   │
                    └─────────────────────┘
```

For full architecture details, see [docs/architecture.md](docs/architecture.md).

## Repository Structure

```
├── ansible/
│   ├── ansible.cfg                   # Ansible configuration
│   ├── requirements.yml              # Ansible Galaxy dependencies (kubernetes.core)
│   ├── inventory/networking/         # Inventory & group variables
│   │   ├── hosts.yml                 # Control plane + worker node definitions
│   │   └── group_vars/all/
│   │       ├── vars.yml              # Variable mappings (references vault)
│   │       └── vault.example         # Template for vault-encrypted secrets
│   └── configurations/
│       ├── networking.yml            # Full-stack playbook (VMs → K8s → apps)
│       ├── apps.yml                  # Application-only playbook (skip infra)
│       └── roles/                    # Individual component roles
│           ├── vms/                  # Proxmox VM provisioning via Terraform
│           ├── kubernetes/           # K8s v1.31 bootstrapping (containerd + kubeadm)
│           ├── metallb/              # L2 load balancer (Terraform layer-2)
│           ├── longhorn/             # Distributed block storage
│           ├── cert-manager/         # TLS automation (Let's Encrypt + Cloudflare)
│           ├── pangolin-newt/        # VPN tunnel deployment
│           ├── traefik/              # Ingress controller
│           ├── pihole/               # DNS with ad-blocking
│           ├── loki/                 # Log aggregation (SingleBinary + S3)
│           ├── tempo/                # Distributed tracing (SingleBinary + S3)
│           ├── kube-prometheus-stack/ # Prometheus + Alertmanager
│           └── alloy/                # Grafana Alloy telemetry collector
├── apps/                             # Helm values & Kubernetes manifests
│   ├── alloy/                        # Grafana Alloy collector configuration
│   ├── cert-manager/                 # TLS certificate automation
│   ├── fleetdock/                    # FleetDock application values
│   ├── kube-prometheus-stack/        # Prometheus + Alertmanager values
│   ├── loki/                         # Log aggregation values + manifests
│   ├── longhorn/                     # Distributed block storage values
│   ├── metallb/                      # L2 load balancer manifests
│   ├── pangolin-newt/                # VPN tunnel values + manifests
│   └── pihole/                       # DNS values (via ArgoCD)
├── scripts/                          # Operational automation scripts
└── kubeconfig                        # Cluster access (gitignored)
```

## Quick Start

### Prerequisites

- Terraform with the Proxmox provider (`bpg/proxmox`)
- Ansible 2.15+ with the `kubernetes.core` collection
- `kubectl` (v1.31+) and `helm` (v3.x) CLI tools
- Access to a Proxmox hypervisor
- A `terraform.tfvars` file for each Terraform layer (see [docs/development.md](docs/development.md))
- An Ansible vault file with cluster secrets

### 1. Install Ansible Dependencies

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### 2. Provision VMs

```bash
./scripts/vms.sh
```

Creates control plane and worker VMs on Proxmox via Terraform, distributes SSH keys, and configures host entries.

### 3. Bootstrap Kubernetes

```bash
./scripts/kubernetes.sh
```

Installs containerd, kubeadm, kubelet, and kubectl on all nodes. Initializes the control plane, joins workers, and deploys the Flannel CNI.

### 4. Deploy Applications

```bash
./scripts/apps.sh
```

Deploys the full application stack: Longhorn, cert-manager, Pangolin/Newt, Traefik, Loki, Tempo, and Pi-hole.

### Full Redeploy

```bash
./scripts/redeploy.sh
```

Runs the entire pipeline end-to-end: VM provisioning, Kubernetes bootstrap, MetalLB, and all applications.

## Configuration Reference

All sensitive configuration is managed through Ansible vault-encrypted variables. The vault file is created from `ansible/inventory/networking/group_vars/all/vault.example`.

| Category | Key Variables | Description |
|----------|--------------|-------------|
| SSH | `ssh_user`, `ssh_key_path` | SSH access to cluster nodes |
| Kubernetes | `kubernetes_version`, `pod_network_cidr` | K8s version and pod networking |
| Networking | `metallb_ip_range`, `networking_traefik_server_ip` | MetalLB pool and Traefik LB address |
| TLS | `cloudflare_api_token`, `letsencrypt_email` | DNS-01 challenge credentials |
| VPN | `pangolin_endpoint`, `newt_id`, `newt_secret` | Pangolin tunnel configuration |
| DNS | `pihole_url` | Pi-hole ingress hostname |
| Monitoring | `grafana_admin_user`, `grafana_admin_password` | Grafana dashboard credentials |
| Storage | `minio_root_user`, `minio_root_password` | S3-compatible backend credentials |
| Proxmox | `proxmox_api_token_id`, `proxmox_api_token_secret` | Hypervisor API access |

## Deployment Scripts

| Script | Command | Purpose | Requires `-K` |
|--------|---------|---------|---------------|
| `vms.sh` | `ansible-playbook ... roles/vms.yml` | Provision Proxmox VMs | Yes |
| `kubernetes.sh` | `ansible-playbook ... roles/kubernetes.yml` | Bootstrap K8s cluster | Yes |
| `apps.sh` | `ansible-playbook ... apps.yml` | Deploy application stack | No |
| `redeploy.sh` | `ansible-playbook ... networking.yml` | Full infrastructure redeploy | Yes |

All scripts use the `ansible/inventory/networking` inventory. Scripts requiring sudo on target hosts use the `-K` flag to prompt for the become password.

## Playbook Execution Order

The full `networking.yml` playbook imports roles in this order:

1. **vms** — Provision Proxmox VMs, distribute SSH keys, configure `/etc/hosts`
2. **kubernetes** — Install containerd + kubeadm, initialize control plane, join workers, deploy Flannel CNI
3. **metallb** — Deploy MetalLB via Terraform layer-2, configure IP address pool and L2 advertisement
4. **longhorn** — Deploy Longhorn distributed storage (3 replicas, 200% over-provisioning)
5. **cert-manager** — Install CRDs, deploy cert-manager, create Cloudflare DNS-01 ClusterIssuer
6. **pangolin-newt** — Deploy Newt VPN tunnel endpoint
7. **traefik** — Deploy Traefik ingress controller with MetalLB LoadBalancer IP
8. **pihole** — Deploy Pi-hole DNS with IngressRoute and dedicated LoadBalancer IP

The `apps.yml` playbook skips VM provisioning and Kubernetes bootstrap, starting from `longhorn`. It also includes `loki` and `tempo` roles for the observability pipeline.

## Further Documentation

- [Architecture](docs/architecture.md) — Component diagram, data flows, design decisions, and invariants
- [Development](docs/development.md) — Local setup, prerequisites, build commands, and troubleshooting
- [Changelog](CHANGELOG.md) — Release history
