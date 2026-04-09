# Architecture

## System Overview

The networking cluster is a bare-metal Kubernetes deployment automated end-to-end with Ansible and Terraform. It serves two primary functions:

1. **Network services** -- DNS filtering (Pi-hole), ingress routing (Traefik), TLS automation (cert-manager), and VPN access (Pangolin-Newt)
2. **Observability** -- A full metrics/logs/traces pipeline (Prometheus, Loki, Tempo) unified by Grafana Alloy as the telemetry collector

The cluster operates within a segmented multi-VLAN environment. Each VLAN hosts an independent Kubernetes cluster with a dedicated purpose (management, DMZ, public applications, storage, monitoring). This repository manages the networking/infrastructure VLAN.

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Networking Cluster                           │
│                                                                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────┐    │
│  │ Control  │   │ Worker 0 │   │ Worker 1 │   │  Worker N... │    │
│  │  Plane   │   │          │   │          │   │              │    │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └──────┬───────┘    │
│       │              │              │                 │             │
│       └──────────────┴──────────────┴─────────────────┘             │
│                          Flannel CNI                                │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Platform Layer                            │    │
│  │  ┌─────────┐  ┌──────────┐  ┌─────────────┐  ┌──────────┐ │    │
│  │  │ MetalLB │  │ Longhorn │  │Cert-Manager │  │ Traefik  │ │    │
│  │  │  (L2)   │  │(Storage) │  │ (TLS/ACME)  │  │(Ingress) │ │    │
│  │  └─────────┘  └──────────┘  └─────────────┘  └──────────┘ │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                  Service Layer                              │    │
│  │  ┌─────────┐  ┌───────────────┐                             │    │
│  │  │ Pi-hole │  │ Pangolin-Newt │                             │    │
│  │  │  (DNS)  │  │    (VPN)      │                             │    │
│  │  └─────────┘  └───────────────┘                             │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                Observability Layer                           │    │
│  │                                                             │    │
│  │  ┌──────────────────────────────────────────────────────┐   │    │
│  │  │               Grafana Alloy                          │   │    │
│  │  │  ┌────────────┐ ┌───────────┐ ┌──────────────────┐  │   │    │
│  │  │  │  Metrics   │ │   Logs    │ │   Receiver       │  │   │    │
│  │  │  │ DaemonSet  │ │ DaemonSet │ │  (OTLP ingest)   │  │   │    │
│  │  │  └─────┬──────┘ └─────┬─────┘ └────────┬─────────┘  │   │    │
│  │  │        │              │                 │            │   │    │
│  │  │  ┌─────┴──────────────┴─────────────────┴─────────┐  │   │    │
│  │  │  │              Singleton                          │  │   │    │
│  │  │  │  (cluster events, annotation autodiscovery,     │  │   │    │
│  │  │  │   Prometheus Operator objects)                   │  │   │    │
│  │  │  └─────────────────────────────────────────────────┘  │   │    │
│  │  └──────────────────────────────────────────────────────┘   │    │
│  │           │                    │                  │          │    │
│  │           ▼                    ▼                  ▼          │    │
│  │    ┌────────────┐    ┌──────────────┐    ┌────────────┐     │    │
│  │    │ Prometheus │    │     Loki     │    │   Tempo    │     │    │
│  │    │  (metrics) │    │    (logs)    │    │  (traces)  │     │    │
│  │    │  7d retain │    │  30d retain  │    │            │     │    │
│  │    └──────┬─────┘    └──────┬───────┘    └──────┬─────┘     │    │
│  │           │                 │                   │           │    │
│  └───────────┼─────────────────┼───────────────────┼───────────┘    │
│              │                 │                   │                │
└──────────────┼─────────────────┼───────────────────┼────────────────┘
               │                 │                   │
               │                 ▼                   ▼
               │          ┌─────────────────────────────┐
               │          │   External Storage Cluster   │
               │          │         (MinIO S3)           │
               │          │  ┌──────────┐ ┌───────────┐ │
               │          │  │ loki-data│ │tempo-data │ │
               │          │  └──────────┘ └───────────┘ │
               │          └─────────────────────────────┘
               ▼
        ┌─────────────────┐
        │  Hub Grafana     │
        │  (remote read)   │
        └─────────────────┘
```

## Data Flows

### Metrics Pipeline

```
Kubernetes Nodes
  │
  ├── node-exporter (from kube-prometheus-stack) ──► Prometheus
  ├── kube-state-metrics ──────────────────────────► Prometheus
  ├── kubelet metrics ─────────────────────────────► Prometheus
  │
  └── Alloy Metrics DaemonSet
        ├── scrapes pods with prometheus.io/* annotations
        ├── scrapes ServiceMonitors / PodMonitors
        └── remote-writes ──► Prometheus (remote-write-receiver)
                                   │
                                   ├── 7-day local retention (Longhorn PVC)
                                   └── LoadBalancer IP ──► Hub Grafana
```

### Logs Pipeline

```
Pod stdout/stderr
  │
  └── Alloy Logs DaemonSet
        ├── collects container logs
        └── pushes ──► Loki (push API)
                          │
Alloy Singleton            │
  └── Kubernetes events ──►│
                           │
                           ├── 30-day retention
                           └── S3 backend (MinIO on storage cluster)
```

### Traces Pipeline

```
Application (OTLP instrumented)
  │
  └── Alloy Receiver (gRPC/HTTP on standard OTLP ports)
        └── forwards ──► Tempo (OTLP receiver)
                            │
                            ├── Generates span metrics ──► Prometheus
                            └── S3 backend (MinIO on storage cluster)
```

## Key Design Decisions

### Bare-Metal Kubernetes with kubeadm

The cluster is bootstrapped using kubeadm rather than a managed Kubernetes distribution. This provides full control over the cluster lifecycle and avoids vendor lock-in. Flannel is used as the CNI for its simplicity and low overhead.

### MetalLB Layer 2 Mode

MetalLB operates in Layer 2 (ARP) mode rather than BGP. This simplifies the network configuration by not requiring router peering, and is sufficient for a single-subnet bare-metal deployment. Each service of type `LoadBalancer` receives an IP from the configured address pool.

### Longhorn for Persistent Storage

Longhorn provides replicated block storage across worker nodes with a default replica count of 3. It serves as the default `StorageClass` for all persistent volume claims, including Prometheus metrics and Loki local cache.

### Single-Binary Loki and Standalone Tempo

Both Loki and Tempo are deployed in single-binary/standalone mode rather than microservices mode. This reduces resource overhead and operational complexity for a cluster of this scale. Both use an external MinIO instance on a separate storage cluster as their long-term object store.

### Grafana Alloy as Unified Collector

Grafana Alloy replaces individual collectors (Promtail, OTEL Collector, etc.) with a single agent that handles metrics, logs, and traces. It runs as:

- **Metrics DaemonSet** -- Per-node metric scraping with control-plane toleration
- **Logs DaemonSet** -- Per-node container log collection
- **Singleton** -- Cluster-wide events and Prometheus Operator object discovery
- **Receiver** -- OTLP ingest endpoint for application traces

### Prometheus without Grafana

The kube-prometheus-stack deploys Prometheus and its Operator but disables the bundled Grafana. Visualization is handled by a centralized Grafana instance on the hub/monitoring cluster, which reads metrics via Prometheus's LoadBalancer-exposed endpoint.

### DNS-01 TLS Challenges via Cloudflare

Cert-manager uses DNS-01 challenges against the Cloudflare API rather than HTTP-01. This allows issuing wildcard certificates and works for services that are not publicly reachable via HTTP.

### VPN Access with Pangolin-Newt

Pangolin-Newt provides secure admin access to the cluster without exposing services on a public IP. Credentials are stored as a Kubernetes Secret templated from Ansible Vault.

## Infrastructure Provisioning Layers

The Terraform-managed infrastructure is split into two layers:

| Layer | Purpose | Managed By |
|-------|---------|------------|
| `layer-1-infrastructure` | Proxmox VM creation and configuration | `roles/vms` |
| `layer-2-helmapps` | Helm chart deployments (MetalLB, Longhorn) | `roles/metallb` |

This separation ensures VMs are fully provisioned and reachable before any Kubernetes resources are applied.

## Networking Model

```
External Traffic ──► MetalLB (L2 ARP) ──► Traefik Ingress ──► Services
                                      ──► Pi-hole DNS (direct LB)
                                      ──► Prometheus (direct LB)
                                      ──► Loki (direct LB)
                                      ──► Tempo (direct LB)
```

- **Traefik** handles HTTP/HTTPS ingress with TLS termination (certificates from cert-manager)
- **Pi-hole, Prometheus, Loki, Tempo** are exposed directly via MetalLB LoadBalancer services for protocol-level access (DNS/UDP, remote-write, push API, OTLP)

## Security Boundaries

- All secrets are managed through Ansible Vault -- no credentials are stored in plaintext in the repository
- Cloudflare API tokens are scoped to DNS zone editing for certificate challenges
- MinIO credentials for Loki/Tempo are injected as Kubernetes Secrets from vault variables
- VPN credentials are namespace-isolated in a dedicated `newt` namespace
- Pi-hole DNS ad-blocking uses curated blocklists (StevenBlack, Hagezi, OISD, URLhaus, and others)

## Invariants

- The cluster always runs a single control-plane node (not HA); this is a known trade-off for simplicity
- Longhorn replication factor of 3 requires at least 3 healthy worker nodes
- Loki and Tempo depend on the external MinIO instance being reachable from the cluster network
- MetalLB IP pool must not overlap with DHCP or other static assignments on the same VLAN
- All Helm values and Kubernetes manifests are applied from the `apps/` directory -- infrastructure roles only set up prerequisites (namespaces, CRDs, secrets)
