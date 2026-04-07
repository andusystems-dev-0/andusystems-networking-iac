# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- Enabled Traefik CRD installation by uncommenting `installCRDs: true` in Traefik values

## [2026-03-23]

### Fixed
- Exposed Prometheus and Tempo LoadBalancer IPs in Helm values for external access

## [2026-03-17]

### Added
- LGTM observability stack: Loki, Tempo, Alloy, and kube-prometheus-stack roles and Helm values
- Loki deployment with S3-compatible storage backend and log retention configuration

### Fixed
- Loki configuration fixes for single-binary deployment mode
- Loki values corrections for replica count, LoadBalancer exposure, and storage settings
- Multiple LGTM stack integration fixes for monitoring application connectivity

## [2026-03-15]

### Added
- LoadBalancer service restoration for external access

### Changed
- Pi-hole Helm values updated for external DNS access
- Homepage values configuration update

### Fixed
- Pi-hole LoadBalancer IP assignment
- Pi-hole pod network CIDR configuration

## [2026-03-14]

### Added
- Pi-hole DNS filtering deployment with Traefik ingress and HTTPS
- Pi-hole blocklists configuration (StevenBlack, Hagezi, OISD, URLhaus, ThreatFox)
- Traefik IngressRoute for Pi-hole web interface

### Changed
- Pi-hole updated to use LoadBalancer IP via MetalLB
- Pi-hole Helm repository configuration updates
- Networking configuration updates for cluster setup
- Terraform destroy step restored in VM provisioning role
- Repository renamed from fleetdock to networking

### Fixed
- Pi-hole DNS values and LoadBalancer exposure

## [2026-03-14] - Initial Release

### Added
- Initial repository structure with Ansible and Terraform configuration
- VM provisioning on Proxmox via Terraform
- Kubernetes cluster bootstrapping with kubeadm and Flannel CNI
- MetalLB L2 load balancer deployment
- Longhorn distributed storage deployment
- Cert-Manager with Let's Encrypt ACME and Cloudflare DNS-01
- Pangolin-Newt VPN tunnel deployment
- Ansible inventory with vault-based secret management
- Deployment scripts for VMs, Kubernetes, and applications
