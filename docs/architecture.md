# Architecture

## Overview

The networking cluster is a Kubernetes cluster dedicated to providing ingress, DNS, load balancing, TLS automation, and observability for a multi-cluster homelab environment. It is provisioned on a hypervisor via Terraform, bootstrapped with Ansible, and managed through GitOps.

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

## Infrastructure Layers

The cluster is provisioned and configured in two distinct layers:

### Layer 1 — VM Provisioning (Terraform)

Terraform provisions virtual machines on the Proxmox hypervisor:

- **Control plane VM** — Runs the Kubernetes API server, scheduler, and controller manager
- **Worker VMs** — Run workloads; configured with cloud-init for automated setup

Each VM receives a static IP via cloud-init, is tagged for inventory grouping, and is bootstrapped with SSH keys for Ansible access.

**Provider:** `bpg/proxmox` — manages VM lifecycle, cloud images, and network configuration.

### Layer 2 — Helm Apps (Terraform)

A minimal Terraform layer that deploys MetalLB via Helm. This is separated because MetalLB must be available before Ansible roles can assign LoadBalancer IPs to other services.

### Application Layer (Ansible)

All remaining applications are deployed via Ansible roles that apply Helm charts and Kubernetes manifests. This layer depends on both Terraform layers being complete.

## Data Flows

### Ingress Flow

```
Internet ──► VPN Tunnel ──► Traefik (LB IP) ──► Kubernetes Service ──► Pod
                                  │
                                  ├── TLS terminated (cert-manager certs)
                                  └── Routing via IngressRoute CRDs
```

Traefik acts as the sole ingress controller, receiving traffic through a MetalLB-assigned LoadBalancer IP. TLS certificates are automatically provisioned by cert-manager using Let's Encrypt with Cloudflare DNS-01 challenges. Routing rules are defined via Traefik IngressRoute CRDs with cross-namespace support.

### DNS Flow

```
Client DNS Query ──► Pi-hole (LB IP) ──► Upstream resolvers (1.1.1.1, 8.8.8.8)
                          │
                          └── Blocklist filtering (19 curated lists)
                              Query logging enabled
```

Pi-hole is exposed via a dedicated MetalLB LoadBalancer IP on the standard DNS port. It filters queries against comprehensive blocklists (StevenBlack, Hagezi, OISD, and others) before forwarding to upstream resolvers.

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

**Alloy** (Grafana's telemetry collector) is deployed by the management cluster and runs on every node. It collects:

- **Metrics** — Scraped from node-exporter, kube-state-metrics, ServiceMonitors, and annotation-based autodiscovery. Written to the local Prometheus instance.
- **Logs** — All pod stdout/stderr and Kubernetes events. Pushed to the local Loki instance.
- **Traces** — Received via OTLP (gRPC and HTTP). Forwarded to the local Tempo instance.

Loki and Tempo use an external S3-compatible object store for long-term data persistence. Prometheus retains metrics locally for 7 days with persistent volume storage.

All three backends expose LoadBalancer IPs so that a centralized Grafana instance on the monitoring cluster can query them directly.

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

### SingleBinary Observability

Loki and Tempo run in SingleBinary mode (single replica) rather than microservices mode. This fits the homelab scale — a single pod per service is sufficient, reduces resource overhead, and simplifies debugging.

### External S3 for Log/Trace Storage

Loki and Tempo persist data to an S3-compatible object store on a dedicated storage cluster rather than local volumes. This decouples storage capacity from the networking cluster's disk, enables cross-cluster data durability, and allows the networking cluster to be torn down without losing observability data.

### Longhorn with 3-Replica Default

Longhorn is configured with a 3-replica default even though it adds overhead. This protects against single-node failures for stateful workloads (Prometheus TSDB, Loki WAL, Tempo WAL) that cannot tolerate data loss.

### MetalLB L2 Mode

MetalLB runs in Layer 2 advertisement mode, which is simpler than BGP and sufficient for a flat network topology. Each service that needs external access gets a dedicated IP from the configured pool.

## Invariants

- **All secrets are vault-encrypted** — No plaintext credentials in the repository. All sensitive values are referenced as Ansible vault variables.
- **MetalLB must be deployed before any LoadBalancer service** — The layer-2 Terraform apply must succeed before any Ansible application role runs.
- **cert-manager CRDs must exist before ClusterIssuers** — The cert-manager role installs CRDs first, then waits for CRD registration before applying ClusterIssuer resources.
- **Flannel CNI is required** — The Kubernetes role deploys Flannel for pod networking. Pods will not schedule until the CNI is available.
- **Kubeconfig is fetched to repo root** — After Kubernetes bootstrapping, the kubeconfig is copied locally for subsequent Ansible roles and manual `kubectl` access. This file is gitignored.

## Concurrency Model

Deployment is sequential by design:

1. **VM provisioning** — Serial (Terraform manages state locks)
2. **Kubernetes bootstrap** — Control plane first, then workers join in parallel
3. **MetalLB** — Must complete before any other application
4. **Application roles** — Executed in playbook order; each role assumes the previous one succeeded

There is no parallel application deployment. This is intentional — roles have implicit dependencies (e.g., cert-manager must exist before Traefik can reference ClusterIssuers, Longhorn must exist before Loki can claim PVCs).
