# Architecture

## Overview

The andusystems-networking repository provisions and configures a Kubernetes cluster dedicated to networking services and observability. It operates within a segmented network environment where different functional domains (management, public applications, storage, monitoring) are isolated on separate network segments.

The deployment is split into two logical layers, each managed by a combination of Terraform and Ansible.

## Layers

### Layer 1: Infrastructure

Terraform provisions virtual machines on a Proxmox hypervisor. Ansible then bootstraps a Kubernetes cluster using kubeadm with the Flannel CNI plugin for pod networking.

```
┌─────────────────────────────────────────────────────┐
│                  Proxmox Hypervisor                  │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │  Control  │  │ Worker 0 │  │ Worker N │   ...    │
│  │  Plane    │  │          │  │          │          │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │              │              │                │
│       └──────────────┼──────────────┘                │
│                      │                               │
│              ┌───────┴───────┐                       │
│              │   Network     │                       │
│              │   Segment     │                       │
│              └───────────────┘                       │
└─────────────────────────────────────────────────────┘
```

**Components:**
- **Terraform** creates VMs with Ubuntu cloud images, configures networking and SSH keys
- **Ansible** installs Kubernetes prerequisites (containerd, kubelet, kubeadm, kubectl)
- **kubeadm** initializes the control plane and joins worker nodes
- **Flannel** provides the pod overlay network

### Layer 2: Platform Services

Once the cluster is running, Ansible deploys platform services via Helm charts and Kubernetes manifests.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   Core Services                         │    │
│  │                                                         │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │    │
│  │  │ MetalLB  │  │ Longhorn │  │    Cert-Manager      │  │    │
│  │  │ (L2 LB)  │  │ (Storage)│  │ (TLS via ACME/DNS01)│  │    │
│  │  └──────────┘  └──────────┘  └──────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                Networking Services                       │    │
│  │                                                         │    │
│  │  ┌──────────────┐  ┌──────────────┐                     │    │
│  │  │  Pi-hole      │  │ Pangolin-Newt│                     │    │
│  │  │ (DNS filter)  │  │   (VPN)      │                     │    │
│  │  └──────────────┘  └──────────────┘                     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Observability Stack (LGTM)                  │    │
│  │                                                         │    │
│  │  ┌──────────┐  ┌────────┐  ┌───────┐  ┌─────────────┐  │    │
│  │  │Prometheus│  │  Loki  │  │ Tempo │  │   Alloy     │  │    │
│  │  │(Metrics) │  │ (Logs) │  │(Trace)│  │(Collectors) │  │    │
│  │  └──────────┘  └────────┘  └───────┘  └─────────────┘  │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flows

### Telemetry Pipeline

Grafana Alloy serves as the unified telemetry collector, shipping data to the three LGTM backends:

```
                    ┌─────────────────────┐
                    │    Alloy Collectors  │
                    │  (DaemonSet + Jobs)  │
                    └──┬──────┬───────┬───┘
                       │      │       │
               Metrics │ Logs │ Traces│
                       │      │       │
                  ┌────▼──┐ ┌─▼────┐ ┌▼──────┐
                  │Prom-  │ │ Loki │ │ Tempo │
                  │etheus │ │      │ │       │
                  └───────┘ └──────┘ └───────┘
                       │      │       │
                       └──────┼───────┘
                              │
                     ┌────────▼────────┐
                     │ S3-compatible   │
                     │ object storage  │
                     │ (MinIO)         │
                     └─────────────────┘
```

**Metrics flow:**
1. Alloy scrapes Kubernetes nodes, pods, kubelet, and cAdvisor endpoints
2. Alloy respects `ServiceMonitor` and `PodMonitor` CRDs for autodiscovery
3. Metrics are pushed to Prometheus via remote-write
4. Prometheus stores metrics with a 7-day retention on Longhorn-backed persistent volumes

**Logs flow:**
1. Alloy collects pod logs from all namespaces
2. Kubernetes events are also captured
3. Logs are pushed to Loki
4. Loki stores log data in an S3-compatible backend with a 30-day retention policy

**Traces flow:**
1. Instrumented applications send traces via OTLP (gRPC or HTTP)
2. Alloy forwards traces to Tempo
3. Tempo generates span metrics and pushes them to Prometheus
4. Trace data is stored in S3-compatible storage

### DNS Filtering

```
  Client DNS Query
        │
        ▼
  ┌──────────┐     ┌──────────────┐
  │  Pi-hole  │────▶│  Upstream    │
  │  (filter) │     │  Resolvers   │
  └──────────┘     └──────────────┘
        │
  LoadBalancer
  (MetalLB L2)
```

Pi-hole is exposed as a LoadBalancer service via MetalLB, allowing network clients to use it as their DNS server. Blocked queries are filtered using curated blocklists (StevenBlack, Hagezi, OISD, URLhaus, ThreatFox, and others). Non-blocked queries are forwarded to upstream public DNS resolvers.

### TLS Certificate Automation

```
  ┌──────────────┐     ┌─────────────┐     ┌───────────┐
  │ Cert-Manager │────▶│  Let's      │────▶│ Cloudflare│
  │ (ClusterIssuer)    │  Encrypt    │     │  DNS API  │
  └──────────────┘     │  ACME       │     └───────────┘
                       └─────────────┘
```

Cert-Manager uses a ClusterIssuer configured for Let's Encrypt with DNS-01 challenges via the Cloudflare API. This enables automatic provisioning and renewal of TLS certificates for all cluster services without requiring inbound HTTP access for HTTP-01 challenges.

## Key Design Decisions

### Ansible + Terraform Hybrid

Terraform handles infrastructure provisioning (VMs, Helm releases for MetalLB) while Ansible orchestrates the full deployment workflow, including running Terraform, bootstrapping Kubernetes, and applying Kubernetes manifests. This separation keeps infrastructure-as-code declarative while allowing imperative orchestration for ordering dependencies.

### MetalLB L2 Mode

MetalLB operates in L2 (ARP) mode, allocating IPs from a configured range on the local network segment. This avoids the complexity of BGP peering while providing stable external IPs for LoadBalancer services in a bare-metal environment.

### Longhorn as Default StorageClass

Longhorn is deployed as the cluster-wide default StorageClass, providing replicated block storage across worker nodes. This enables persistent volumes for all stateful workloads (Prometheus, Loki, Tempo, Pi-hole) without external storage infrastructure.

### Spoke-Cluster Observability Pattern

This cluster runs the full observability backends (Prometheus, Loki, Tempo) but disables the Grafana UI. Visualization is handled by a central Grafana instance in a separate management cluster that queries these backends remotely via their LoadBalancer endpoints. This follows a "spoke cluster" pattern where each cluster owns its telemetry data while dashboards are centralized.

### Alloy as Unified Collector

Grafana Alloy replaces separate Prometheus scrapers, Promtail log shippers, and OpenTelemetry collectors with a single agent. It runs as multiple specialized components (metrics, logs, singleton, receiver) to handle different collection patterns while sharing a common configuration framework.

### DNS-01 Challenges for TLS

Cert-Manager uses DNS-01 challenges via Cloudflare rather than HTTP-01 challenges. This works regardless of whether the cluster has public HTTP ingress, which is important for an internal networking cluster that may not be directly reachable from the internet.

### Vault-Based Secret Management

All sensitive values (API tokens, credentials, IPs) are stored in Ansible Vault rather than in plaintext. Variables follow a `vault_` prefix convention, and `no_log: true` is used for tasks that handle secrets to prevent them from appearing in Ansible output.

## Deployment Ordering

The deployment sequence is critical because services have dependencies:

```
VMs (Terraform)
 └── Kubernetes (kubeadm)
      ├── MetalLB        ← required for LoadBalancer services
      ├── Longhorn        ← required for persistent storage
      ├── Cert-Manager    ← required for TLS certificates
      ├── Pangolin-Newt   ← VPN (independent)
      ├── Pi-hole         ← DNS (depends on MetalLB)
      ├── Prometheus      ← metrics (depends on MetalLB, Longhorn)
      ├── Loki            ← logs (depends on MetalLB, Longhorn)
      ├── Tempo           ← traces (depends on MetalLB, Longhorn)
      └── Alloy           ← collectors (depends on Prometheus, Loki, Tempo)
```

Alloy must be deployed last because it requires all three telemetry backends to be available as push targets. MetalLB and Longhorn must be deployed before any services that require LoadBalancer IPs or persistent volumes.
