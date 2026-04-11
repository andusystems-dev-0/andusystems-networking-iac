# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Pi-hole namespace creation in deployment role.
- Traefik role added to networking cluster deployment pipeline.

### Changed
- Modified Traefik task import path in apps playbook.
- Cleaned up and reorganized apps.yml role imports.
- Replaced Terraform executable task with destroy operation for layer-1 infrastructure in Ansible playbook.
- Updated retries and error handling for improved reliability in VM provisioning.
- Refactored Ansible configurations for improved readability and organization.
- Standardized line endings in shell scripts.
- Updated playbook imports and enhanced variable definitions.
- Removed obsolete tasks and ensured consistent formatting across all role files.

### Fixed
- Enabled Traefik CRD installation.
- Consolidated Pi-hole LoadBalancer IP to values.yml as single source of truth.

## [2026-04-07]

### Added
- Inline comments explaining complex Ansible logic.
- Inline comments to `variables.tf` files.
- Deployment Scripts section to README.
- Comments to explain RBAC configuration in Traefik values.

### Changed
- Consolidated duplicate Terraform variables into shared file.
- Consolidated common variables between layer-1 and layer-2 Terraform configurations.
- Extracted common Ansible task includes and split large task files.

### Fixed
- Enabled Traefik CRD installation.
- Consolidated Pi-hole LoadBalancer IP to Helm values as single source of truth.

## [2026-03-23]

### Changed
- Exposed networking Prometheus and Tempo values to include LoadBalancer IPs for cross-cluster access.

## [2026-03-17]

### Added
- Loki, Tempo, and Prometheus (LGTM stack) values and deployment configurations.
- Loki SingleBinary deployment with S3-compatible backend for log storage.
- Tempo deployment with OTLP receivers and S3-compatible backend for trace storage.
- ServiceMonitor resources for Loki and Tempo.

### Changed
- Updated networking Loki config for LoadBalancer exposure.
- Updated networking Loki values for LoadBalancer IP assignment.
- Updated networking cluster for monitoring app fixes.

### Fixed
- Fixed networking Loki values and configuration.
- Fixed issues with the LGTM stack deployment.
- Removed Loki replicas (switched to SingleBinary mode).

## [2026-03-15]

### Added
- Pi-hole deployment with Traefik IngressRoute for HTTPS access.
- Pod CIDR to Pi-hole Helm values.
- LoadBalancer service for Pi-hole DNS exposure.
- Comprehensive DNS blocklists (19 curated sources).

### Changed
- Updated Helm values for external access to Pi-hole as a DNS server.
- Updated Pi-hole Helm repository reference.
- Updated Pi-hole values for DNS upstream configuration.

### Fixed
- Fixed LoadBalancer IP in Pi-hole values.

## [2026-03-14]

### Added
- Initial repository setup with full infrastructure-as-code structure.
- Terraform layer-1 for Proxmox VM provisioning (control plane + workers).
- Terraform layer-2 for MetalLB Helm deployment.
- Ansible roles: VMs, Kubernetes, MetalLB, Longhorn, cert-manager, Pangolin/Newt.
- Deployment scripts for VMs, Kubernetes, applications, and full redeploy.
- Pi-hole deployment with Traefik exposure.
- Networking cluster initial configuration.

### Changed
- Renamed project from fleetdock to networking.
- Added Terraform destroy step to `vms.yml`.
