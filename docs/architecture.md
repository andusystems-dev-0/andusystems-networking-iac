# Architecture

## Overview

The networking cluster is a Kubernetes cluster dedicated to providing ingress, DNS, load balancing, TLS automation, and observability for a multi-cluster homelab environment. It is provisioned on a hypervisor via Terraform, bootstrapped with Ansible, and managed through GitOps.

This cluster operates as a spoke in a hub-and-spoke model. A central ArgoCD instance on a separate management cluster manages the application state, while a centralized Grafana instance on a monitoring cluster queries the observability backends exposed here.

## Component Diagram

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

## Component Summary

| Component | Role | Deployment | Exposed |
|-----------|------|------------|---------|
| MetalLB | L2 LoadBalancer IP assignment | Terraform (layer-2 Helm) | N/A — infrastructure |
| Traefik | Ingress controller, TLS termination | Ansible role (Helm v32.1.1) | LoadBalancer IP |
| Pi-hole | DNS ad-blocking, upstream forwarding | Ansible role (Helm) | LoadBalancer IP (DNS) + IngressRoute (web UI) |
| cert-manager | TLS certificate automation | Ansible role (Helm + CRDs v1.14.4) | Internal only |
| Longhorn | Distributed block storage | Ansible role (Helm) | Internal only |
| Pangolin/Newt | VPN tunnel endpoint | Ansible role (Helm) | ClusterIP |
| Prometheus | Metrics TSDB (7-day retention) | Ansible role (kube-prometheus-stack Helm) | LoadBalancer IP |
| Loki | Log aggregation (SingleBinary, 30-day retention) | Ansible role (Helm) | LoadBalancer IP |
| Tempo | Distributed tracing (SingleBinary) | Ansible role (manifest) | LoadBalancer IP |
| Alloy | Telemetry collector (metrics, logs, traces) | Ansible role (Helm) | Internal only |
| Alertmanager | Alert routing | Deployed with kube-prometheus-stack | Internal only |

## Infrastructure Layers

The cluster is provisioned and configured in three distinct layers that must execute in order:

```
┌───────────────────────────────────────┐
│  Layer 1 — Terraform (VMs)            │  Proxmox VM provisioning
│  Control plane + worker VMs           │  Cloud-init, static IPs, SSH keys
└───────────────┬───────────────────────┘
                ▼
┌───────────────────────────────────────┐
│  Ansible — Kubernetes Bootstrap       │  containerd, kubeadm, Flannel CNI
│  Control plane init → worker join     │  Kubeconfig fetched locally
└───────────────┬───────────────────────┘
                ▼
┌───────────────────────────────────────┐
│  Layer 2 — Terraform (MetalLB Helm)   │  MetalLB must exist before any
│  IPAddressPool + L2Advertisement      │  service can get a LoadBalancer IP
└───────────────┬───────────────────────┘
                ▼
┌───────────────────────────────────────┐
│  Ansible — Application Roles          │  Sequential: Longhorn → cert-manager
│  Helm charts + K8s manifests          │  → Pangolin → Traefik → Pi-hole
│                                       │  → Loki → Tempo → Alloy
└───────────────────────────────────────┘
```

### Layer 1 — VM Provisioning (Terraform)

Terraform provisions virtual machines on the Proxmox hypervisor:

- **Control plane VM** — Runs the Kubernetes API server, scheduler, and controller manager
- **Worker VMs** — Run workloads; configured with cloud-init for automated setup

Each VM receives a static IP via cloud-init, is tagged for inventory grouping, and is bootstrapped with SSH keys for Ansible access.

**Provider:** `bpg/proxmox` — manages VM lifecycle, cloud images, and network configuration.

### Layer 2 — Helm Apps (Terraform)

A minimal Terraform layer that deploys MetalLB via Helm. This is separated because MetalLB must be available before Ansible roles can assign LoadBalancer IPs to other services.

### Application Layer (Ansible)

All remaining applications are deployed via Ansible roles that apply Helm charts and Kubernetes manifests. Each role:
- Creates the target namespace if needed
- Deploys the Helm chart or applies raw manifests via `kubernetes.core`
- Templates secrets from Ansible vault variables into Kubernetes Secret resources
- Waits for readiness where necessary (e.g., cert-manager CRD registration)

## Data Flows

### Ingress Flow

```
Internet ──► VPN Tunnel ──► Traefik (LB IP) ──► Kubernetes Service ──► Pod
                                  │
                                  ├── TLS terminated (cert-manager certs)
                                  └── Routing via IngressRoute CRDs
```

Traefik acts as the sole ingress controller, receiving traffic through a MetalLB-assigned LoadBalancer IP. TLS certificates are automatically provisioned by cert-manager using Let's Encrypt with Cloudflare DNS-01 challenges. Routing rules are defined via Traefik IngressRoute CRDs with cross-namespace support enabled.

### DNS Flow

```
Client DNS Query ──► Pi-hole (LB IP) ──► Upstream resolvers
                          │
                          └── Blocklist filtering (19 curated lists)
                              Query logging enabled
```

Pi-hole is exposed via a dedicated MetalLB LoadBalancer IP on the standard DNS port. It filters queries against comprehensive blocklists (StevenBlack, Hagezi, OISD, and others) before forwarding to upstream public resolvers. The Pi-hole web UI is accessible via a Traefik IngressRoute with HTTPS.

### Observability Flow

```
┌─────────────┐     ┌─────────────┐     ┌───────────────┐
│   Alloy     │────►│    Loki     │────►│  External S3  │
│ (pod logs)  │     │ (log store) │     │  (long-term)  │
└─────────────┘     └─────────────┘     └───────────────┘

┌─────────────┐     ┌─────────────┐     ┌───────────────┐
│   Alloy     │────►│   Tempo     │────►│  External S3  │
│ (OTLP recv) │     │(trace store)│     │  (long-term)  │
└─────────────┘     └─────────────┘     └───────────────┘

┌─────────────┐     ┌──────────────┐
│   Alloy     │────►│  Prometheus  │
│ (metrics)   │     │ (metric TSDB)│
└─────────────┘     └──────────────┘
```

**Alloy** (Grafana's telemetry collector) runs on every node. It collects:

- **Metrics** — Scraped from node-exporter, kube-state-metrics, ServiceMonitors, and annotation-based autodiscovery. Written to the local Prometheus instance via remote write.
- **Logs** — All pod stdout/stderr and Kubernetes events. Pushed to the local Loki instance.
- **Traces** — Received via OTLP (gRPC and HTTP). Forwarded to the local Tempo instance.

Loki and Tempo use an external S3-compatible object store on a dedicated storage cluster for long-term data persistence. Prometheus retains metrics locally for 7 days with Longhorn persistent volume storage.

All three observability backends expose LoadBalancer IPs so that a centralized Grafana instance on the monitoring cluster can query them directly.

### Storage Flow

```
Stateful Pod ──► PVC ──► Longhorn StorageClass ──► 3-replica volume
                                                        │
                                                   Distributed across
                                                   worker nodes
```

Longhorn is the default StorageClass. It replicates data across 3 nodes for resilience. Used by Prometheus (TSDB), Loki (WAL + cache), and Alertmanager.

## Key Design Decisions

### Two-Layer Terraform Approach

Infrastructure is split into two Terraform layers to enforce ordering:

1. **Layer 1** provisions VMs — must complete before Kubernetes can be bootstrapped
2. **Layer 2** deploys MetalLB via Helm — must complete before any service can receive a LoadBalancer IP

This separation prevents circular dependencies: Ansible roles need MetalLB IPs, but MetalLB needs a running cluster, which needs VMs.

### Ansible-First Application Deployment

Most Helm charts are deployed through Ansible roles rather than Terraform for several reasons:

- Ansible roles can template Kubernetes manifests alongside Helm values (e.g., Secrets, IngressRoutes)
- Role ordering is explicit in the playbook import sequence
- Vault-encrypted variables integrate naturally with Ansible's variable system

### Hub-and-Spoke Observability

This cluster is a spoke in the observability architecture. It runs its own Prometheus, Loki, and Tempo instances but does **not** run Grafana. A centralized Grafana on the monitoring cluster queries all spoke backends via their LoadBalancer IPs. This keeps dashboarding centralized while keeping telemetry data local to each cluster.

### SingleBinary Observability

Loki and Tempo run in SingleBinary mode (single replica) rather than microservices mode. This fits the homelab scale — a single pod per service is sufficient, reduces resource overhead, and simplifies debugging.

### External S3 for Log/Trace Storage

Loki and Tempo persist data to an S3-compatible object store on a dedicated storage cluster rather than local volumes. This decouples storage capacity from the networking cluster's disk, enables cross-cluster data durability, and allows the networking cluster to be torn down without losing observability data.

### Longhorn with 3-Replica Default

Longhorn is configured with a 3-replica default even though it adds overhead. This protects against single-node failures for stateful workloads (Prometheus TSDB, Loki WAL, Tempo WAL) that cannot tolerate data loss. Over-provisioning is set at 200% with a 15% minimum available threshold.

### MetalLB L2 Mode

MetalLB runs in Layer 2 advertisement mode, which is simpler than BGP and sufficient for a flat network topology. Each service that needs external access gets a dedicated IP from the configured pool.

### Terraform Destroy-Before-Apply for VMs

The VM provisioning role runs a Terraform destroy before applying. This ensures a clean state for the infrastructure layer and prevents drift from manual changes.

## Invariants

- **All secrets are vault-encrypted** — No plaintext credentials in the repository. All sensitive values are referenced as Ansible vault variables.
- **MetalLB must be deployed before any LoadBalancer service** — The layer-2 Terraform apply must succeed before any Ansible application role runs.
- **cert-manager CRDs must exist before ClusterIssuers** — The cert-manager role installs CRDs first, then waits for CRD registration before applying ClusterIssuer resources.
- **Flannel CNI is required** — The Kubernetes role deploys Flannel for pod networking. Pods will not schedule until the CNI is available.
- **Kubeconfig is fetched to repo root** — After Kubernetes bootstrapping, the kubeconfig is copied locally for subsequent Ansible roles and manual `kubectl` access. This file is gitignored.
- **Namespace creation is role-managed** — Each Ansible role creates its own namespace before deploying resources into it.

## Concurrency Model

Deployment is sequential by design:

1. **VM provisioning** — Serial (Terraform manages state locks)
2. **Kubernetes bootstrap** — Control plane first, then workers join in parallel
3. **MetalLB** — Must complete before any other application
4. **Application roles** — Executed in playbook order; each role assumes the previous one succeeded

There is no parallel application deployment. This is intentional — roles have implicit dependencies (e.g., cert-manager must exist before Traefik can reference ClusterIssuers, Longhorn must exist before Loki can claim PVCs).

## GitOps Integration

The `apps/` directory contains Helm values and Kubernetes manifests that serve as the source of truth for ArgoCD. The central ArgoCD instance on the management cluster watches this repository and syncs application state to the networking cluster. Changes to `apps/` are picked up automatically; infrastructure changes (Terraform/Ansible) require manual pipeline execution.
