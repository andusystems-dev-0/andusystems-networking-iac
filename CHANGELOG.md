# Changelog

All notable changes to the andusystems-networking project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Deployment Scripts section in README.
- Inline comments explaining complex Ansible logic.
- Inline comments to Terraform `variables.tf` files.
- RBAC configuration comments in Traefik values.

### Changed
- Consolidated duplicate Terraform variables into shared file.
- Consolidated common variables between layer-1 and layer-2 Terraform configurations.
- Consolidated Pi-hole LoadBalancer IP to Helm `values.yml` as single source of truth.
- Enabled Traefik CRD installation.
- Extracted common Ansible task includes and split large task files.

## [0.4.0] - 2026-03-23

### Changed
- Exposed Prometheus and Tempo values to include LoadBalancer IPs for external access.

## [0.3.0] - 2026-03-17

### Added
- Loki log aggregation deployment with MinIO S3 backend.
- Tempo distributed tracing deployment with MinIO S3 backend.
- Kube-Prometheus-Stack metrics collection.
- Grafana Alloy telemetry collector deployment.
- LGTM (Loki, Grafana, Tempo, Mimir) stack values and deployment configuration.

### Fixed
- Fixed Loki configuration for log ingestion.
- Fixed Loki Helm values for schema and storage settings.
- Fixed issues with the LGTM stack integration.
- Removed Loki replicas (switched to single-binary mode).
- Updated Loki values for LoadBalancer IP exposure.

## [0.2.0] - 2026-03-15

### Added
- Pi-hole DNS filtering deployment.
- Pi-hole Helm values with DNS blocklists (StevenBlack, Hagezi, OISD, URLhaus, and others).
- Pi-hole ingress via Traefik with TLS termination.
- Pod CIDR configuration in Pi-hole Helm values.
- LoadBalancer service for Pi-hole DNS access.

### Changed
- Updated Pi-hole to use Traefik for HTTP/HTTPS exposure.
- Updated Pi-hole Helm chart repository source.
- Updated Pi-hole DNS values and LoadBalancer configuration.

### Fixed
- Fixed LoadBalancer IP assignment in Pi-hole values.

## [0.1.0] - 2026-03-14

### Added
- Initial repository structure and Ansible configuration.
- Proxmox VM provisioning via Terraform (layer-1-infrastructure).
- Kubernetes cluster bootstrapping with kubeadm and Flannel CNI.
- MetalLB bare-metal LoadBalancer (Layer 2 mode) via Terraform (layer-2-helmapps).
- Longhorn distributed block storage.
- Cert-Manager with Let's Encrypt and Cloudflare DNS-01 challenges.
- Pangolin-Newt VPN tunnel deployment.
- Traefik ingress controller.
- FleetDock application values.
- Ansible inventory with controller and worker node definitions.
- Ansible Vault integration for secret management.
- Networking and apps playbooks with ordered role execution.
