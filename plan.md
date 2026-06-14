# Plan: RustDesk Relay + Dispatch Private Resource

> Self-host RustDesk Server OSS (`hbbs` + `hbbr`) on the networking
> cluster as a new Ansible role, then run a Newt agent on the Arch
> gaming desktop tunnelling Dispatch (job scraper UI + API) back to
> Pangolin as private resources. Pangolin resource definitions are
> created manually in the Pangolin admin UI — this plan does not
> automate them. Dual-path access for the gaming PC (LAN-direct +
> Pangolin) preserves remote desktop reachability during Pangolin
> troubleshooting. The relay FQDN is resolved via a `/etc/hosts`
> entry on the gaming PC (LAN path) and Pangolin's overlay DNS
> (remote path) — no dependency on Pi-hole.

## Goals

- New Ansible role `rustdesk-server` deploying `hbbs` and `hbbr`
  to the networking cluster, fitting the repo's existing
  Ansible-first / templated-manifests pattern.
- Single MetalLB IP serving both `hbbs` and `hbbr` ports for
  LAN-direct access (gaming PC client).
- ClusterIP Services that Pangolin's existing Newt agent can target
  as upstreams for the manually-created Pangolin private resource
  (laptop client).
- `/etc/hosts` entry on the gaming PC mapping the relay FQDN to the
  LAN MetalLB IP. The laptop resolves the same FQDN via Pangolin's
  overlay. One `hbbs -r <FQDN>` value satisfies both paths.
- Newt agent on the Arch gaming desktop installed as a system
  systemd service, registered as a new Pangolin site.
- Dispatch services on the gaming PC running as systemd **user**
  services with linger enabled, surviving reboots without graphical
  login.
- Operator runbook in `docs/rustdesk-server.md` covering key
  retrieval, client configuration, and dual-path failover testing.

## Non-goals

- No public internet exposure of any RustDesk port.
- No RustDesk Server **Pro** features (web console, API server,
  multi-relay GeoIP, MaxMind). OSS only.
- No automation of Pangolin resources — created and maintained by
  hand in the Pangolin admin UI.
- No Dispatch refactor — the workspace continues to build with
  `cargo build --release`; only the systemd units and Newt tunnel
  are added.
- No changes to the existing `pangolin-newt` cluster role — that
  remains the cluster's own VPN entry point and is not modified by
  this work.
- No dependency on Pi-hole. Pi-hole can be down or up without
  affecting any path in this deployment.
- No Helm chart — RustDesk Server OSS does not publish one and the
  manifests are small enough to template directly, matching the
  pattern used by `cluster-status` and `pangolin-newt`.

## Architecture

```
                                    ┌──────────────────────────────┐
                                    │   Laptop (remote client)     │
                                    │   - Pangolin/Newt client     │
                                    │   - RustDesk client          │
                                    │   - FQDN resolved by         │
                                    │     Pangolin overlay DNS     │
                                    └──────────────┬───────────────┘
                                                   │ Pangolin overlay
                                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│             Networking Cluster (VLAN 30, 10.238.30.0/24)             │
│                                                                      │
│   ┌─────────────────────────┐    ┌──────────────────────────────┐   │
│   │  pangolin-newt (existing│    │  rustdesk-server (NEW)       │   │
│   │  cluster Newt agent)    │───►│  Service: hbbs (ClusterIP)   │   │
│   │  upstreams ClusterIP    │    │  Service: hbbr (ClusterIP)   │   │
│   │  Services for Pangolin  │    │  Service: rustdesk-lan       │   │
│   │  private resource       │    │   (LoadBalancer, MetalLB IP, │   │
│   └─────────────────────────┘    │    shared-IP, all ports)     │   │
│                                   │  Deployment: hbbs            │   │
│                                   │  Deployment: hbbr            │   │
│                                   │  PVC: rustdesk-data (Longhorn│   │
│                                   │   single replica)            │   │
│                                   └──────────────┬───────────────┘   │
└──────────────────────────────────────────────────┼──────────────────┘
                                                   │ direct LAN
                                                   ▼
                                    ┌──────────────────────────────┐
                                    │   Gaming PC (Arch, VLAN 50)  │
                                    │   - /etc/hosts: FQDN → LAN IP│
                                    │   - RustDesk client          │
                                    │     → connects via LAN IP    │
                                    │       (FQDN resolves locally)│
                                    │   - Newt agent (systemd)     │
                                    │     → tunnels Dispatch UI/API│
                                    │   - Dispatch (systemd user)  │
                                    │     → scraper, scorer, store,│
                                    │       discord, api, ui       │
                                    └──────────────────────────────┘
```

The gaming PC's RustDesk client uses the LAN MetalLB IP (resolved via
`/etc/hosts`). The laptop's RustDesk client uses the same FQDN
resolved by Pangolin's overlay DNS to the cluster ClusterIP. Both
reach the same `hbbs`/`hbbr` pods.

`hbbs -r` accepts only one relay address, so the FQDN is the single
source of truth. The two resolution mechanisms (`/etc/hosts` vs
Pangolin overlay) deliver each client to the right path.

### Why /etc/hosts and not Pi-hole

Three reasons:

1. **Operational independence.** Pi-hole goes down → RustDesk LAN
   path keeps working. Critical given the dual-path-for-Pangolin-debug
   intent of the design.
2. **Surface area.** The gaming PC is the only LAN-side client that
   needs this resolution. A single line on a single host beats a
   cluster-wide DNS service for a one-host need.
3. **Move-friendly.** When you relocate to Kingsport, the
   `/etc/hosts` entry travels with the gaming PC and is trivially
   updated if the LAN IP changes. Pangolin path is unaffected.

## RustDesk port reference

| Service | Protocol | Port  | Purpose                                      |
| ------- | -------- | ----- | -------------------------------------------- |
| hbbs    | TCP      | 21115 | NAT type test                                |
| hbbs    | TCP      | 21116 | TCP hole punching / connection service       |
| hbbs    | UDP      | 21116 | ID server heartbeat / rendezvous (critical)  |
| hbbs    | TCP      | 21118 | WebSocket (web/mobile clients)               |
| hbbr    | TCP      | 21117 | Relay (when hole punching fails)             |
| hbbr    | TCP      | 21119 | Relay WebSocket                              |

## Repository changes

### New paths

```
apps/
└── rustdesk-server/
    ├── README.md                       # component summary + ops notes
    └── manifests/
        └── (nothing — all manifests are role-templated)

ansible/
└── configurations/
    ├── apps.yml                        # MODIFIED: add rustdesk-server role
    ├── networking.yml                  # MODIFIED: add rustdesk-server role
    └── roles/
        ├── rustdesk-server.yml         # NEW: role wrapper playbook
        └── rustdesk-server/
            ├── defaults/main.yml
            ├── tasks/main.yml
            └── templates/
                ├── namespace.yaml.j2
                ├── pvc-rustdesk-data.yaml.j2
                ├── deployment-hbbs.yaml.j2
                ├── deployment-hbbr.yaml.j2
                ├── service-rustdesk-lan.yaml.j2
                └── services-rustdesk-cluster.yaml.j2

ansible/
└── inventory/
    └── networking/
        └── group_vars/
            └── all/
                ├── vault                      # MODIFIED: add new keys
                ├── vault.example              # MODIFIED: add new keys
                └── vars.yml                   # MODIFIED: reference new vault keys

docs/
└── rustdesk-server.md                  # NEW: operator runbook
```

### Modified paths

- `ansible/configurations/apps.yml` — add `rustdesk-server` role import
  after the `pihole` block (or wherever app roles end).
- `ansible/configurations/networking.yml` — same.
- `ansible/inventory/networking/group_vars/all/vault` — new vault
  variables.
- `ansible/inventory/networking/group_vars/all/vault.example` — same
  with placeholder values.

### Untouched

- `apps/pihole/` — no changes.
- `pangolin-newt` role — no changes.

## Vault variables (new)

Add to `ansible/inventory/networking/group_vars/all/vault`:

```yaml
# RustDesk Server OSS
vault_rustdesk_lan_ip: "10.238.30.250"          # adjust to free MetalLB IP
vault_rustdesk_relay_fqdn: "relay.lab.andusystems.com"
vault_rustdesk_namespace: "rustdesk-server"
```

Add to `vault.example` with placeholder values:

```yaml
vault_rustdesk_lan_ip: "10.0.0.0"
vault_rustdesk_relay_fqdn: "relay.example.com"
vault_rustdesk_namespace: "rustdesk-server"
```

Add to `ansible/inventory/networking/group_vars/all/vars.yml`
(unencrypted — references vault):

```yaml
rustdesk_lan_ip: "{{ vault_rustdesk_lan_ip }}"
rustdesk_relay_fqdn: "{{ vault_rustdesk_relay_fqdn }}"
rustdesk_namespace: "{{ vault_rustdesk_namespace }}"
```

The `id_ed25519` keypair is generated by `hbbs` on first start in
`/root` inside the container (mounted as the `rustdesk-data` PVC). It
is **not** stored in the vault; the public key is fetched post-deploy
and distributed to clients out-of-band. See the runbook.

## Verify MetalLB IP availability before deploy

```sh
# From the repo root, with kubeconfig fetched:
export KUBECONFIG=$PWD/kubeconfig
kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.loadBalancerIP}{"\n"}{end}' | sort -u
# Confirm vault_rustdesk_lan_ip is not in this list AND is in the
# metallb_ip_range pool.
```

## Role files — copy-paste ready

### `ansible/configurations/roles/rustdesk-server/defaults/main.yml`

```yaml
---
# Image
rustdesk_image: "rustdesk/rustdesk-server"
rustdesk_image_tag: "latest"

# Storage
rustdesk_pvc_size: "1Gi"
rustdesk_storage_class: "longhorn"

# Resources
rustdesk_hbbs_cpu_request: "50m"
rustdesk_hbbs_memory_request: "64Mi"
rustdesk_hbbs_cpu_limit: "500m"
rustdesk_hbbs_memory_limit: "256Mi"

rustdesk_hbbr_cpu_request: "50m"
rustdesk_hbbr_memory_request: "64Mi"
rustdesk_hbbr_cpu_limit: "500m"
rustdesk_hbbr_memory_limit: "256Mi"
```

### `ansible/configurations/roles/rustdesk-server/tasks/main.yml`

```yaml
---
- name: Create rustdesk-server namespace
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ lookup('template', 'namespace.yaml.j2') | from_yaml }}"
  tags:
    - rustdesk-server
    - install

- name: Create rustdesk-data PVC
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ lookup('template', 'pvc-rustdesk-data.yaml.j2') | from_yaml }}"
  tags:
    - rustdesk-server
    - install

- name: Deploy hbbs (signaling/rendezvous)
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ lookup('template', 'deployment-hbbs.yaml.j2') | from_yaml }}"
  tags:
    - rustdesk-server
    - install

- name: Deploy hbbr (relay)
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ lookup('template', 'deployment-hbbr.yaml.j2') | from_yaml }}"
  tags:
    - rustdesk-server
    - install

- name: Apply LAN LoadBalancer Services (MetalLB)
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ item }}"
  loop: "{{ lookup('template', 'service-rustdesk-lan.yaml.j2') | from_yaml_all | list }}"
  tags:
    - rustdesk-server
    - install

- name: Apply ClusterIP Services for Pangolin upstreams
  kubernetes.core.k8s:
    state: present
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    definition: "{{ item }}"
  loop: "{{ lookup('template', 'services-rustdesk-cluster.yaml.j2') | from_yaml_all | list }}"
  tags:
    - rustdesk-server
    - install

- name: Wait for hbbs to be Available
  kubernetes.core.k8s_info:
    kind: Deployment
    name: hbbs
    namespace: "{{ rustdesk_namespace }}"
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    wait: true
    wait_condition:
      type: Available
      status: "True"
    wait_timeout: 180
  tags:
    - rustdesk-server
    - install

- name: Wait for hbbr to be Available
  kubernetes.core.k8s_info:
    kind: Deployment
    name: hbbr
    namespace: "{{ rustdesk_namespace }}"
    kubeconfig: "{{ playbook_dir }}/../../kubeconfig"
    wait: true
    wait_condition:
      type: Available
      status: "True"
    wait_timeout: 180
  tags:
    - rustdesk-server
    - install
```

### `ansible/configurations/roles/rustdesk-server/templates/namespace.yaml.j2`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ rustdesk_namespace }}
  labels:
    app.kubernetes.io/name: rustdesk-server
    app.kubernetes.io/managed-by: ansible
```

### `ansible/configurations/roles/rustdesk-server/templates/pvc-rustdesk-data.yaml.j2`

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustdesk-data
  namespace: {{ rustdesk_namespace }}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: {{ rustdesk_storage_class }}
  resources:
    requests:
      storage: {{ rustdesk_pvc_size }}
```

### `ansible/configurations/roles/rustdesk-server/templates/deployment-hbbs.yaml.j2`

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hbbs
  namespace: {{ rustdesk_namespace }}
  labels:
    app: hbbs
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hbbs
  template:
    metadata:
      labels:
        app: hbbs
    spec:
      securityContext:
        fsGroup: 0
      containers:
        - name: hbbs
          image: "{{ rustdesk_image }}:{{ rustdesk_image_tag }}"
          imagePullPolicy: IfNotPresent
          args:
            - "hbbs"
            - "-r"
            - "{{ rustdesk_relay_fqdn }}:21117"
          ports:
            - { name: nat-test,  containerPort: 21115, protocol: TCP }
            - { name: tcp-punch, containerPort: 21116, protocol: TCP }
            - { name: udp-rndvz, containerPort: 21116, protocol: UDP }
            - { name: ws,        containerPort: 21118, protocol: TCP }
          volumeMounts:
            - name: data
              mountPath: /root
          resources:
            requests:
              cpu: "{{ rustdesk_hbbs_cpu_request }}"
              memory: "{{ rustdesk_hbbs_memory_request }}"
            limits:
              cpu: "{{ rustdesk_hbbs_cpu_limit }}"
              memory: "{{ rustdesk_hbbs_memory_limit }}"
          readinessProbe:
            tcpSocket:
              port: 21116
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 21116
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustdesk-data
```

### `ansible/configurations/roles/rustdesk-server/templates/deployment-hbbr.yaml.j2`

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hbbr
  namespace: {{ rustdesk_namespace }}
  labels:
    app: hbbr
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hbbr
  template:
    metadata:
      labels:
        app: hbbr
    spec:
      securityContext:
        fsGroup: 0
      containers:
        - name: hbbr
          image: "{{ rustdesk_image }}:{{ rustdesk_image_tag }}"
          imagePullPolicy: IfNotPresent
          args:
            - "hbbr"
          ports:
            - { name: relay,    containerPort: 21117, protocol: TCP }
            - { name: relay-ws, containerPort: 21119, protocol: TCP }
          volumeMounts:
            - name: data
              mountPath: /root
          resources:
            requests:
              cpu: "{{ rustdesk_hbbr_cpu_request }}"
              memory: "{{ rustdesk_hbbr_memory_request }}"
            limits:
              cpu: "{{ rustdesk_hbbr_cpu_limit }}"
              memory: "{{ rustdesk_hbbr_memory_limit }}"
          readinessProbe:
            tcpSocket:
              port: 21117
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 21117
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustdesk-data
```

> **Why both deployments share the same PVC:** `hbbr` reads the
> `id_ed25519` keypair generated by `hbbs` to encrypt relay traffic.
> ReadWriteOnce works because both pods land on the same node when the
> single-replica Longhorn volume is attached; if pod scheduling
> separates them, drop a `podAffinity` rule onto `hbbr` targeting
> `app=hbbs`. For homelab single-node-attach this is fine.

### `ansible/configurations/roles/rustdesk-server/templates/service-rustdesk-lan.yaml.j2`

Two Services share the same MetalLB IP via the `allow-shared-ip`
annotation:

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-lan-hbbs
  namespace: {{ rustdesk_namespace }}
  annotations:
    metallb.universe.tf/allow-shared-ip: "rustdesk-lan"
    metallb.universe.tf/loadBalancerIPs: "{{ rustdesk_lan_ip }}"
spec:
  type: LoadBalancer
  loadBalancerIP: "{{ rustdesk_lan_ip }}"
  externalTrafficPolicy: Local
  selector:
    app: hbbs
  ports:
    - { name: nat-test,  port: 21115, targetPort: 21115, protocol: TCP }
    - { name: tcp-punch, port: 21116, targetPort: 21116, protocol: TCP }
    - { name: udp-rndvz, port: 21116, targetPort: 21116, protocol: UDP }
    - { name: ws,        port: 21118, targetPort: 21118, protocol: TCP }
---
apiVersion: v1
kind: Service
metadata:
  name: rustdesk-lan-hbbr
  namespace: {{ rustdesk_namespace }}
  annotations:
    metallb.universe.tf/allow-shared-ip: "rustdesk-lan"
    metallb.universe.tf/loadBalancerIPs: "{{ rustdesk_lan_ip }}"
spec:
  type: LoadBalancer
  loadBalancerIP: "{{ rustdesk_lan_ip }}"
  externalTrafficPolicy: Local
  selector:
    app: hbbr
  ports:
    - { name: relay,    port: 21117, targetPort: 21117, protocol: TCP }
    - { name: relay-ws, port: 21119, targetPort: 21119, protocol: TCP }
```

`externalTrafficPolicy: Local` preserves real client source IPs in
`hbbs` logs (matters for troubleshooting; `hbbs` only sees the
container IP otherwise).

### `ansible/configurations/roles/rustdesk-server/templates/services-rustdesk-cluster.yaml.j2`

ClusterIP Services for the Pangolin upstream (the cluster's existing
`pangolin-newt` agent will target these by DNS name when the manual
Pangolin resource is created):

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: hbbs
  namespace: {{ rustdesk_namespace }}
spec:
  type: ClusterIP
  selector:
    app: hbbs
  ports:
    - { name: nat-test,  port: 21115, targetPort: 21115, protocol: TCP }
    - { name: tcp-punch, port: 21116, targetPort: 21116, protocol: TCP }
    - { name: udp-rndvz, port: 21116, targetPort: 21116, protocol: UDP }
    - { name: ws,        port: 21118, targetPort: 21118, protocol: TCP }
---
apiVersion: v1
kind: Service
metadata:
  name: hbbr
  namespace: {{ rustdesk_namespace }}
spec:
  type: ClusterIP
  selector:
    app: hbbr
  ports:
    - { name: relay,    port: 21117, targetPort: 21117, protocol: TCP }
    - { name: relay-ws, port: 21119, targetPort: 21119, protocol: TCP }
```

DNS names for Pangolin upstream config (entered manually in admin UI):

- `hbbs.rustdesk-server.svc.cluster.local`
- `hbbr.rustdesk-server.svc.cluster.local`

## Playbook integration

### `ansible/configurations/roles/rustdesk-server.yml` (NEW wrapper)

```yaml
---
- name: Deploy RustDesk Server
  hosts: networking-control
  become: false
  gather_facts: false
  roles:
    - rustdesk-server
```

### `ansible/configurations/apps.yml`

Add the role import after the existing `pihole` block. Match the
existing import style used by other roles in the file:

```yaml
# ... existing roles (longhorn, cert-manager, pangolin-newt,
# traefik, loki, tempo, pihole) ...

- name: Deploy RustDesk Server (OSS)
  hosts: networking-control
  become: false
  gather_facts: false
  roles:
    - rustdesk-server
  tags:
    - rustdesk-server
    - install
```

> **Adapt the `hosts:` value** to match the inventory group used by
> other app roles in the file (likely `networking-control` or
> similar — check the existing entries).

### `ansible/configurations/networking.yml`

Same role import added at the bottom.

### Standalone invocation

Following the established pattern from `docs/development.md`:

```sh
ansible-playbook \
  -i ansible/inventory/networking \
  ansible/configurations/roles/rustdesk-server.yml \
  --tags rustdesk-server,install \
  --ask-vault-pass
```

## Phase 1 — RustDesk relay in cluster

### Step 1.1 — Plan repo changes (no deploy)

1. Create the role skeleton:
   ```sh
   mkdir -p ansible/configurations/roles/rustdesk-server/{defaults,tasks,templates}
   mkdir -p apps/rustdesk-server
   ```
2. Drop in all `.yml` and `.yaml.j2` files from this plan.
3. Add vault keys to `vault` and `vault.example`.
4. Add `vars.yml` references.
5. Add the role wrapper playbook
   `ansible/configurations/roles/rustdesk-server.yml`.
6. Update `apps.yml` and `networking.yml` to import the role.
7. Write `docs/rustdesk-server.md` (see "Operator runbook" below).
8. Write `apps/rustdesk-server/README.md` (one-pager mirroring other
   `apps/*/README.md` files).

### Step 1.2 — Pre-deploy verification

```sh
# Verify MetalLB IP free and in-pool
export KUBECONFIG=$PWD/kubeconfig
kubectl get svc -A | awk '{print $5}' | sort -u | grep -F "{{ vault_rustdesk_lan_ip }}" \
  && echo "ERROR: IP in use" || echo "OK: IP free"

# Verify Longhorn storage class exists
kubectl get sc longhorn
```

### Step 1.3 — Deploy

```sh
# Encrypt the updated vault if not already encrypted
ansible-vault encrypt ansible/inventory/networking/group_vars/all/vault

# Deploy just rustdesk-server
ansible-playbook \
  -i ansible/inventory/networking \
  ansible/configurations/roles/rustdesk-server.yml \
  --tags rustdesk-server,install \
  --ask-vault-pass
```

### Step 1.4 — Post-deploy verification

```sh
# Pods Running, restart count 0
kubectl -n rustdesk-server get pods

# PVC Bound
kubectl -n rustdesk-server get pvc rustdesk-data

# LAN LoadBalancer IP assigned to both Services
kubectl -n rustdesk-server get svc

# hbbs generated the keypair
kubectl -n rustdesk-server exec deploy/hbbs -- ls -la /root | grep id_ed25519
kubectl -n rustdesk-server exec deploy/hbbs -- cat /root/id_ed25519.pub

# Save the public key locally for client distribution
mkdir -p ~/.config/rustdesk
kubectl -n rustdesk-server exec deploy/hbbs -- cat /root/id_ed25519.pub \
  > ~/.config/rustdesk/server.pub

# UDP 21116 reachable from LAN
nc -uvz {{ vault_rustdesk_lan_ip }} 21116

# TCP 21115/21116/21117/21118/21119 reachable from LAN
for port in 21115 21116 21117 21118 21119; do
  nc -vz {{ vault_rustdesk_lan_ip }} $port
done
```

### Step 1.5 — Gaming PC `/etc/hosts` and RustDesk client (LAN-only test)

Add the FQDN-to-LAN-IP mapping:

```sh
# On the gaming PC
echo "{{ vault_rustdesk_lan_ip }}  {{ vault_rustdesk_relay_fqdn }}" \
  | sudo tee -a /etc/hosts

# Verify resolution
getent hosts {{ vault_rustdesk_relay_fqdn }}
# Expected output: <LAN-IP>  <FQDN>
```

Install the RustDesk client:

```sh
yay -S rustdesk-bin
```

Open RustDesk → Settings → Network → ID/Relay Server:

- ID Server: `{{ vault_rustdesk_relay_fqdn }}` (resolves via
  `/etc/hosts` to `{{ vault_rustdesk_lan_ip }}`)
- Relay Server: leave blank (deduced from `hbbs -r` flag)
- API Server: leave blank
- Key: paste contents of `~/.config/rustdesk/server.pub` (single line,
  starts with `ed25519:` or is the raw base64 — match what `hbbs`
  emitted)

Test connection from a phone (Android/iOS RustDesk) on the same LAN
to the gaming PC's RustDesk ID. Add the same FQDN/IP entry to the
phone's RustDesk Settings → Network → ID/Relay Server. Connect
should show "Ready / Connected" with the green indicator.

> **Note for phone test:** Android RustDesk has no `/etc/hosts`, so
> the phone client should use the **LAN IP directly** as ID Server
> for this one-off test. The FQDN matters only for the gaming PC and
> the laptop (where Pangolin handles resolution).

**Phase 1 exit criteria:**

- `hbbs` and `hbbr` pods Running, no restarts after 1 hour.
- LAN MetalLB IP serves all 6 ports (5 TCP + 1 UDP) cleanly.
- Gaming PC `/etc/hosts` resolves the FQDN to the LAN IP.
- LAN-only RustDesk session established between two devices.
- `id_ed25519.pub` saved locally.

## Phase 2 — Newt + Dispatch on the gaming PC

### Step 2.1 — Manually create Pangolin resources (admin UI)

In the existing Pangolin admin UI:

1. **New site** for the gaming PC.
   - Name: `gaming-desktop` (or similar).
   - Note the generated `NEWT_ID`, `NEWT_SECRET`, and
     `PANGOLIN_ENDPOINT` — these go into the gaming PC's
     `/etc/newt/newt.env`.

2. **New private resource: rustdesk-relay** (under the existing
   cluster site, NOT the gaming PC site).
   - Public hostname: `{{ rustdesk_relay_fqdn }}`
   - Upstream targets:
     - `hbbs.rustdesk-server.svc.cluster.local:21115/tcp`
     - `hbbs.rustdesk-server.svc.cluster.local:21116/tcp`
     - `hbbs.rustdesk-server.svc.cluster.local:21116/udp`
     - `hbbs.rustdesk-server.svc.cluster.local:21118/tcp`
     - `hbbr.rustdesk-server.svc.cluster.local:21117/tcp`
     - `hbbr.rustdesk-server.svc.cluster.local:21119/tcp`
   - **Critical:** confirm UDP 21116 is supported. If Pangolin's
     resource UI doesn't expose UDP, see "Fallback: TCP-only mode"
     below.

3. **New private resource: dispatch-ui** (under the gaming PC site).
   - Public hostname: e.g. `dispatch.lab.andusystems.com`
   - Upstream: `127.0.0.1:5173` (the gaming PC's local SvelteKit port)
   - Protocol: TCP

4. **New private resource: dispatch-api** (under the gaming PC site).
   - Public hostname: e.g. `dispatch-api.lab.andusystems.com`
   - Upstream: `127.0.0.1:8080` (or whatever the `api` crate binds)
   - Protocol: TCP

### Step 2.2 — Install Newt on the gaming PC

```sh
# Pin a specific version for reproducibility
NEWT_VERSION="1.10.3"
sudo curl -fsSL \
  "https://github.com/fosrl/newt/releases/download/${NEWT_VERSION}/newt_linux_amd64" \
  -o /usr/local/bin/newt
sudo chmod 0755 /usr/local/bin/newt
/usr/local/bin/newt --version  # confirm
```

### Step 2.3 — Configure Newt

Following the official Pangolin docs pattern:

```sh
sudo install -d -m 0755 /etc/newt
sudo tee /etc/newt/newt.env > /dev/null <<'EOF'
NEWT_ID=<paste-from-pangolin>
NEWT_SECRET=<paste-from-pangolin>
PANGOLIN_ENDPOINT=https://<your-pangolin-endpoint>
EOF
sudo chmod 600 /etc/newt/newt.env
```

### Step 2.4 — Newt systemd unit

```sh
sudo tee /etc/systemd/system/newt.service > /dev/null <<'EOF'
[Unit]
Description=Newt - Pangolin Tunnel Connector
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/newt/newt.env
ExecStart=/usr/local/bin/newt
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now newt
sudo systemctl status newt
journalctl -u newt -f   # watch initial connect; expect "Online" status in Pangolin UI
```

> **Why `User=root`:** Newt creates a userspace WireGuard tunnel via
> netstack — no kernel `wg` interface, no `NET_ADMIN` cap needed —
> but `/etc/newt/newt.env` is `0600` root, and Newt's default state
> dir under `/etc/newt` requires write access. Running as root is
> the documented Pangolin pattern. If hardening is desired later,
> create a `newt` system user with explicit ownership of `/etc/newt`.

### Step 2.5 — Dispatch as systemd user services

Per-crate units. Adjust `WorkingDirectory` and `ExecStart` paths to
match the actual Dispatch repo location on the gaming PC.

```sh
mkdir -p ~/.config/systemd/user
mkdir -p ~/.config/dispatch
```

#### `~/.config/systemd/user/dispatch-store.service`

```ini
[Unit]
Description=Dispatch store (SQLite-backed config + state)
After=network.target

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch
ExecStart=%h/code/dispatch/target/release/store
Restart=on-failure
RestartSec=5
EnvironmentFile=%h/.config/dispatch/store.env
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

#### `~/.config/systemd/user/dispatch-api.service`

```ini
[Unit]
Description=Dispatch API
After=network.target dispatch-store.service
Requires=dispatch-store.service

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch
ExecStart=%h/code/dispatch/target/release/api
Restart=on-failure
RestartSec=5
EnvironmentFile=%h/.config/dispatch/api.env
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

#### `~/.config/systemd/user/dispatch-scraper.service`

```ini
[Unit]
Description=Dispatch scraper (job board crawler)
After=network.target dispatch-store.service
Requires=dispatch-store.service

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch
ExecStart=%h/code/dispatch/target/release/scraper
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.config/dispatch/scraper.env
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

#### `~/.config/systemd/user/dispatch-scorer.service`

```ini
[Unit]
Description=Dispatch scorer (4-pass LLM scoring pipeline)
After=network.target dispatch-store.service
Requires=dispatch-store.service

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch
ExecStart=%h/code/dispatch/target/release/scorer
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.config/dispatch/scorer.env
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

#### `~/.config/systemd/user/dispatch-discord.service`

```ini
[Unit]
Description=Dispatch Discord delivery bot
After=network.target dispatch-store.service
Requires=dispatch-store.service

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch
ExecStart=%h/code/dispatch/target/release/discord
Restart=on-failure
RestartSec=10
EnvironmentFile=%h/.config/dispatch/discord.env
Environment=RUST_LOG=info

[Install]
WantedBy=default.target
```

#### `~/.config/systemd/user/dispatch-ui.service`

SvelteKit needs a Node runtime. Using `node build` from a `vite build`
output:

```ini
[Unit]
Description=Dispatch SvelteKit UI
After=network.target dispatch-api.service
Requires=dispatch-api.service

[Service]
Type=simple
WorkingDirectory=%h/code/dispatch/ui
ExecStart=/usr/bin/node build/index.js
Restart=on-failure
RestartSec=5
EnvironmentFile=%h/.config/dispatch/ui.env
Environment=PORT=5173
Environment=HOST=127.0.0.1
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
```

> **Bind `127.0.0.1`, not `0.0.0.0`.** The UI is reachable only via
> Newt → Pangolin; binding to localhost prevents accidental LAN
> exposure if Newt fails open.

### Step 2.6 — Enable lingering and start everything

```sh
# Survive logout / reboot without graphical login
sudo loginctl enable-linger $USER

# Reload user systemd
systemctl --user daemon-reload

# Enable + start, in dependency order
systemctl --user enable --now dispatch-store.service
systemctl --user enable --now dispatch-api.service
systemctl --user enable --now dispatch-scraper.service
systemctl --user enable --now dispatch-scorer.service
systemctl --user enable --now dispatch-discord.service
systemctl --user enable --now dispatch-ui.service

# Verify
systemctl --user status 'dispatch-*'
```

### Step 2.7 — Laptop client config

```sh
# Laptop (assumes Pangolin client already configured for the cluster)
yay -S rustdesk-bin   # or platform equivalent
```

The laptop's Pangolin client resolves `{{ rustdesk_relay_fqdn }}`
through the overlay — no `/etc/hosts` entry needed on the laptop.

RustDesk → Settings → Network → ID/Relay Server:

- ID Server: `{{ rustdesk_relay_fqdn }}` (resolves via Pangolin
  overlay)
- Relay Server: blank
- Key: same `id_ed25519.pub` saved in Phase 1.5

Browser test: `https://dispatch.lab.andusystems.com` should load the
SvelteKit UI without RustDesk.

**Phase 2 exit criteria:**

- Newt service `Online` in Pangolin admin UI.
- All six `dispatch-*` user services Active.
- Laptop establishes RustDesk session via Pangolin path.
- Laptop loads Dispatch UI in a browser via Pangolin path.
- After `sudo systemctl stop newt` on the gaming PC: Dispatch UI
  becomes unreachable from laptop, but **gaming PC RustDesk client
  still shows green** because it uses the LAN MetalLB path
  (`/etc/hosts` resolution is unaffected by Newt status).
- After `kubectl -n pangolin scale deploy pangolin --replicas=0` (or
  equivalent cluster-side disruption): laptop loses access, gaming
  PC RustDesk client still works on LAN.

## Fallback: TCP-only mode (UDP unsupported by Pangolin)

If Phase 2.1 reveals that Pangolin private resources don't accept
UDP, force `hbbs` to never use hole punching. All laptop traffic
will flow through `hbbr` over TCP 21117 — slightly higher latency,
but functional.

Edit `templates/deployment-hbbs.yaml.j2`:

```yaml
        env:
          - name: ALWAYS_USE_RELAY
            value: "Y"
        args:
          - "hbbs"
          - "-r"
          - "{{ rustdesk_relay_fqdn }}:21117"
```

Re-deploy via the role. Drop UDP 21116 from the manual Pangolin
resource. LAN clients still get hole punching since the LAN Service
keeps UDP 21116 — only the Pangolin path is forced to relay.

## Operator runbook (`docs/rustdesk-server.md`)

Stub content to write during Phase 1.1:

```markdown
# RustDesk Server (OSS) Runbook

## Component summary

Self-hosted RustDesk Server OSS in the networking cluster. `hbbs`
handles signaling/rendezvous, `hbbr` handles relay-mode traffic.
Single MetalLB IP serves both. ClusterIP Services back the manual
Pangolin private resource. The relay FQDN is resolved on the gaming
PC via `/etc/hosts` and on remote clients via Pangolin's overlay DNS.

## Key retrieval

Public key for client configuration:

    kubectl -n rustdesk-server exec deploy/hbbs -- cat /root/id_ed25519.pub

Save to `~/.config/rustdesk/server.pub` for distribution.

## Key rotation

The keypair is generated by hbbs on first start. To rotate:

    kubectl -n rustdesk-server delete pvc rustdesk-data
    kubectl -n rustdesk-server rollout restart deploy/hbbs deploy/hbbr

A new keypair is generated. Re-distribute the new public key to all
clients before they reconnect — clients with the old key will fail to
verify the server.

## Backup

The PVC contains the keypair and a small config file. Periodic
backup:

    kubectl -n rustdesk-server cp \
      $(kubectl -n rustdesk-server get pod -l app=hbbs -o name | head -1):/root \
      ~/backups/rustdesk-data-$(date +%F)

## DNS resolution paths

The single relay FQDN must resolve to two different paths depending
on the client:

| Client       | Resolution mechanism      | Resolves to                          |
| ------------ | ------------------------- | ------------------------------------ |
| Gaming PC    | `/etc/hosts`              | LAN MetalLB IP                       |
| Laptop       | Pangolin overlay DNS      | Cluster ClusterIP via Pangolin tunnel|
| Phone (LAN)  | Direct IP in client config| LAN MetalLB IP                       |

If the gaming PC's LAN IP changes (new MetalLB pool after a move),
update `/etc/hosts`:

    sudo sed -i 's|^.*<old-ip>.*relay.lab.andusystems.com.*$||' /etc/hosts
    echo "<new-ip>  relay.lab.andusystems.com" | sudo tee -a /etc/hosts

## Dual-path failover tests

LAN path independence:

    sudo systemctl stop newt          # on gaming PC
    # → Dispatch UI unreachable from laptop ✓
    # → Gaming PC RustDesk client still green ✓ (LAN MetalLB)
    sudo systemctl start newt

Pangolin path independence:

    kubectl -n pangolin scale deploy pangolin --replicas=0
    # → Laptop loses both Dispatch and RustDesk Pangolin access ✗
    # → Gaming PC RustDesk client still green ✓ (LAN MetalLB)
    kubectl -n pangolin scale deploy pangolin --replicas=1

## Common issues

**Client shows "Connecting..." forever**: check `/etc/hosts` resolves
the relay FQDN (gaming PC) or that the Pangolin overlay reaches the
cluster ClusterIP (laptop). Check `kubectl -n rustdesk-server logs
deploy/hbbs` for handshake errors.

**Gaming PC client offline despite green LED**: the green status comes
from the local heartbeat to hbbs, not from a verified relay. Try
initiating an actual session.

**hbbs reports relay address mismatch**: the `-r` flag in the
deployment must match the FQDN configured in clients AND the FQDN
the gaming PC's `/etc/hosts` resolves. All three must agree.

**Pi-hole down or unreachable**: irrelevant to this deployment. The
relay path uses `/etc/hosts`, not Pi-hole.
```

## Validation checklist (combined Phase 1 + 2)

- [ ] Vault keys added; vault re-encrypted; `vault.example` updated.
- [ ] MetalLB IP confirmed free and in pool.
- [ ] Role files in place and syntactically valid (`ansible-lint
      ansible/configurations/roles/rustdesk-server`).
- [ ] `apps.yml` and `networking.yml` reference the role.
- [ ] `kubectl -n rustdesk-server get pods` shows `hbbs` and `hbbr`
      Running with restart count 0 after 1 hour.
- [ ] PVC `rustdesk-data` Bound, contains `id_ed25519` +
      `id_ed25519.pub`.
- [ ] Both LAN Services have the same `EXTERNAL-IP` matching
      `vault_rustdesk_lan_ip`.
- [ ] All 6 ports reachable on LAN (5 TCP + 1 UDP).
- [ ] ClusterIP Services `hbbs` and `hbbr` resolvable via in-cluster
      DNS.
- [ ] Manual Pangolin resources created for relay, dispatch-ui,
      dispatch-api.
- [ ] Gaming PC `/etc/hosts` contains FQDN → LAN IP entry; `getent
      hosts <FQDN>` returns the LAN IP.
- [ ] Newt v1.10.3 binary at `/usr/local/bin/newt` with correct
      execute bit; `newt --version` matches.
- [ ] `/etc/newt/newt.env` mode 0600 root:root.
- [ ] `newt.service` Active, Pangolin admin UI shows the gaming PC
      site as Online.
- [ ] All six `dispatch-*` user services Active.
- [ ] `loginctl show-user $USER | grep Linger=yes`.
- [ ] Gaming PC RustDesk: green status, ID Server is the FQDN.
- [ ] Laptop RustDesk: green status, ID Server is the FQDN, session
      to gaming PC works.
- [ ] Laptop browser: Dispatch UI loads at the Pangolin FQDN.
- [ ] LAN-path failover test: `systemctl stop newt` on gaming PC;
      Dispatch UI breaks, RustDesk LAN path still works.
- [ ] Pangolin-path failover test: scale Pangolin to 0 replicas;
      gaming PC RustDesk LAN path still works.
- [ ] No RustDesk port appears in Cloudflare DNS or Pangolin's
      public resource list.
- [ ] `id_ed25519.pub` saved in `~/.config/rustdesk/server.pub` on
      both gaming PC and laptop, contents match cluster PVC.

## Open questions (resolve during execution)

These don't block starting Phase 1, but should be answered before
Phase 2:

1. **Does Pangolin in this version support UDP private resources?**
   Discoverable at the manual resource creation step — if the UI
   doesn't expose UDP, switch to TCP-only mode (see fallback section).

2. **Inventory group for the `rustdesk-server` role's `hosts:`**
   value — match what other app roles use in `apps.yml`.

3. **Two-Newt-sites topology** — adding the gaming PC site to a
   Pangolin instance that already has a cluster site. Generally
   supported, but version-dependent. If the admin UI rejects a
   second site, the deployment plan is unaffected; only the manual
   resource creation differs.

## Risks and mitigations

| Risk                                                                | Mitigation                                                                                            |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| UDP 21116 unsupported by Pangolin → no hole punching from laptop    | `ALWAYS_USE_RELAY=Y` fallback. Documented above. Latency penalty only.                                |
| `/etc/hosts` entry on gaming PC wiped by NetworkManager or similar  | `/etc/hosts` is not managed by NetworkManager by default on Arch. Verify with `cat /etc/nsswitch.conf` shows `files dns` order. |
| `hbbs -r` mismatch between deployment, /etc/hosts, and client config| Single source of truth: `vault_rustdesk_relay_fqdn`. All three (deployment arg, hosts file, client config) read from the same value. |
| Pangolin upgrade breaks laptop access                               | LAN path independent. Failover by walking to LAN, SSH from another LAN host, or using a tailnet side-channel. |
| Gaming PC Newt agent failure → Dispatch UI unreachable from laptop  | RustDesk into the gaming PC, `journalctl -u newt`, restart Newt. Dispatch keeps running.              |
| `id_ed25519` lost on PVC corruption                                 | Longhorn 3-replica default + scheduled `kubectl cp` backup (see runbook).                             |
| Pod scheduling separates `hbbs` and `hbbr` from shared PVC          | Add podAffinity to `hbbr` targeting `app=hbbs`. Single-node test cluster won't hit this.              |
| Newt v1.10.3 incompatible with Pangolin server version              | Pin Newt version in install script; Pangolin release notes flag breaking client changes.              |
| Gaming PC reboots and Dispatch doesn't restart                      | `enable-linger` ensures user services start at boot. Validation checklist verifies.                   |
| Move to Kingsport changes LAN subnet                                | Update `/etc/hosts` entry on gaming PC and `vault_rustdesk_lan_ip`; re-deploy role. Pangolin path unaffected. |
| Pi-hole down                                                        | No impact on this deployment — relay FQDN never resolved through Pi-hole.                             |

## Effort estimate

| Phase                                                | Estimate     |
| ---------------------------------------------------- | ------------ |
| 1.1 — Repo changes (role + manifests + docs)           | 1.25 hours |
| 1.2 — Pre-deploy verification                          | 15 min     |
| 1.3 — Deploy via ansible-playbook                      | 15 min     |
| 1.4 — Post-deploy verification + LAN client            | 30 min     |
| 1.5 — `/etc/hosts` + LAN-only test                     | 15 min     |
| 2.1 — Manual Pangolin resources (3)                    | 30 min     |
| 2.2–2.4 — Newt install + systemd                       | 30 min     |
| 2.5–2.6 — Dispatch user services                       | 1 hour     |
| 2.7 — Laptop client + browser tests                    | 15 min     |
| Failover validation                                    | 30 min     |
| **Total**                                              | **5 hours**|

## Post-implementation

- Add this rollout to `CHANGELOG.md`.
- Update `docs/architecture.md` with the rustdesk-server component
  in the component diagram and a brief note in "Components" table.
- Update root `README.md` "Components" table with the new row.
- Schedule a 30-day retest of failover paths to confirm operational
  resilience holds.
