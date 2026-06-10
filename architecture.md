# Cinemates — Architecture Reference

> Cinemates is a production-grade GitOps platform hosting a full-stack social application for the film industry. The repository is a mixed monorepo containing application code (React SPA and Node.js/Express API), Terraform infrastructure modules for GCP, Helm charts, and ArgoCD manifests. The single most important architectural decision is the GitOps image-tag commit loop: GitHub Actions builds an image, writes the tag back into `helm-charts/*/values.yaml`, and ArgoCD automatically reconciles the cluster from the same repository — no external CD system, no manual `kubectl apply`.

---

## Table of Contents

1. [Repository Layout](#1-repository-layout)
2. [Infrastructure Layer](#2-infrastructure-layer)
3. [Application Layer](#3-application-layer)
4. [Kubernetes / GitOps Layer](#4-kubernetes--gitops-layer)
5. [Networking & Traffic Flow](#5-networking--traffic-flow)
6. [CI/CD Pipeline](#6-cicd-pipeline)
7. [Security Architecture](#7-security-architecture)
8. [Observability Stack](#8-observability-stack)
9. [Autoscaling](#9-autoscaling)
10. [Local Development](#10-local-development)
11. [Data Architecture](#11-data-architecture)
12. [Architecture Decisions & Rationale](#12-architecture-decisions--rationale)
13. [Known Gaps & Recommendations](#13-known-gaps--recommendations)
14. [Dependency Graph](#14-dependency-graph)
15. [Glossary](#15-glossary)

---

## 1. Repository Layout

**Type:** Mixed monorepo — application source, infrastructure IaC, Helm charts, and GitOps manifests all in one repository.

```
cinemates-devops/
├── backend/                  # Node.js/Express API source code
│   ├── controllers/          # Route handlers (auth, chat, posts, etc.)
│   ├── models/               # Mongoose ODM schemas
│   ├── routes/               # Express route definitions
│   ├── middleware/            # JWT auth middleware
│   ├── socket.js             # Socket.io server initialization
│   ├── index.js              # Application entry point
│   └── Dockerfile            # Single-stage: node:18-alpine, non-root
├── frontend/                 # React 18 SPA (Vite + TailwindCSS)
│   ├── src/                  # Application source
│   ├── nginx.conf            # nginx SPA fallback + asset caching config
│   └── Dockerfile            # Multi-stage: node:18-alpine build → nginx:alpine
├── helm-charts/              # Helm charts (source of truth for ArgoCD)
│   ├── backend/              # Express API deployment + HTTPRoute
│   ├── frontend/             # React/nginx deployment + HTTPRoute
│   └── gateway/              # Shared GKE Gateway API resource
├── argo-apps/                # ArgoCD Application manifests (App of Apps children)
│   ├── backend.yaml
│   ├── frontend.yaml
│   └── gateway.yaml
├── infra/                    # Terraform modules (independent state per module)
│   ├── vpc/                  # VPC, subnets, Cloud Router, Cloud NAT
│   ├── gke/                  # GKE cluster, node pools, NAP
│   ├── iam/                  # Service accounts, WIF pools/providers, IAM bindings
│   ├── gsm/                  # Google Secret Manager secret creation
│   ├── gcr/                  # Artifact Registry repositories
│   ├── gks-addons/           # ArgoCD, KEDA, PostgreSQL, SonarQube (Helm via TF)
│   └── monitoring/           # Prometheus, Grafana, Loki, Promtail (Helm via TF)
├── .github/workflows/        # GitHub Actions CI pipelines
│   ├── backend-pipeline.yaml
│   └── frontend-pipeline.yaml
├── Phases.md                 # Project delivery phases (planning doc)
├── todo.md                   # Outstanding work items
└── README.md                 # Project overview and architecture diagram
```

---

## 2. Infrastructure Layer

### 2.1 IaC Overview

- **Toolchain:** Terraform (hashicorp/google provider v6.8.0)
- **State backend:** GCS bucket `cinemates-tf-state`, one prefix per module (`vpc`, `gke`, `iam`, etc.)
- **State locking:** GCS object versioning (built-in for GCS Terraform backend)
- **Module organization:** Flat — seven independent root modules, each in its own directory with its own `backend.tf`, `provider.tf`, and `tfvars/dev.tfvars`. Modules read outputs from sibling modules using `terraform_remote_state` data sources.
- **Workspaces:** Used. Each module is deployed with `terraform workspace select dev`.
- **Provider:** `google = 6.8.0`, project `cinemates-497209`, region `us-east1`, default zone `us-east1-b`.

### 2.2 Module Map

**Module: `infra/vpc/`**
- Purpose: Baseline networking for the cluster
- Resources: `google_compute_network`, `google_compute_subnetwork`, `google_compute_router`, `google_compute_router_nat`
- Key inputs: `project_id`, `project_name`, `region`
- Key outputs: `vpc_network_id`, `subnet_name`, `gke_subnet_id`
- Depends on: none (entry point)
- Notable: VPC-native cluster enabled via secondary IP ranges (pods `10.48.0.0/14`, services `10.52.0.0/20`); Cloud NAT with `AUTO_ONLY` allocation provides outbound internet access for private nodes.

**Module: `infra/gke/`**
- Purpose: GKE Standard cluster and node pools
- Resources: `google_container_cluster`, `google_container_node_pool` (for_each), `google_service_account`, `google_project_iam_member`
- Key inputs: `node_pools` map, `gke_version`, `environment`, VPC outputs (via remote state)
- Key outputs: `cluster_name`, `cluster_endpoint` (sensitive), `cluster_ca_certificate` (sensitive), `kubeconfig` (template-rendered, sensitive)
- Depends on: `vpc` (remote state for network IDs)
- Notable: Gateway API enabled at cluster level (`CHANNEL_STANDARD`); Dataplane v2 (`ADVANCED_DATAPATH` = Cilium eBPF CNI); NAP (Node Auto-Provisioning) enabled alongside explicit node pools; `remove_default_node_pool = true`.

**Module: `infra/iam/`**
- Purpose: CI/CD identity and role assignments
- Resources: `google_service_account`, `google_iam_workload_identity_pool`, `google_iam_workload_identity_pool_provider`, `google_service_account_iam_member`, `google_project_iam_member`
- Key inputs: `service_accounts` map, `workload_identity_pools` map, `project_iam_bindings` map
- Key outputs: `service_accounts` (email map), `workload_identity_providers` (name map)
- Depends on: none
- Notable: WIF OIDC provider trusts `token.actions.githubusercontent.com`; grants `github-actions-sa` the `roles/artifactregistry.writer` role.

**Module: `infra/gsm/`**
- Purpose: Create Google Secret Manager secrets (shells only — values populated separately)
- Resources: `google_secret_manager_secret`
- Key inputs: `secret_id`, `project_id`, `region`
- Key outputs: none
- Depends on: none
- Notable: Dual-region replication (`us-east1` + `us-west1`); `deletion_protection = false`. Currently creates a single secret `dev-secret`.

**Module: `infra/gcr/`**
- Purpose: Artifact Registry Docker repositories
- Resources: `google_artifact_registry_repository` (for_each)
- Key inputs: `repositories` map (format, description)
- Key outputs: none
- Depends on: none
- Creates: `cinemates-backend` and `cinemates-frontend` repositories at `us-east1-docker.pkg.dev/cinemates-497209/`.

**Module: `infra/gks-addons/`**
- Purpose: Kubernetes platform tooling via Helm, bootstrapped by Terraform
- Resources: `helm_release` (ArgoCD, KEDA, PostgreSQL, SonarQube), `kubernetes_secret` (ArgoCD repo creds), `kubectl_manifest` (root-app, ArgoCD HTTPRoute)
- Key inputs: `project_id`, GKE remote state (provider configuration)
- Depends on: `gke` (remote state for cluster access)
- Deploys:
  - ArgoCD v7.7.12 (`argo-cd` chart) in `argocd` namespace
  - KEDA v2.20.0 in `keda` namespace
  - PostgreSQL v15.5.0 (Bitnami) in `database` namespace
  - SonarQube v2026.3.1 in `sonarqube` namespace
  - Root ArgoCD Application (App of Apps) from `argo-apps/` path

**Module: `infra/monitoring/`**
- Purpose: Observability stack via Helm
- Resources: `helm_release` × 4
- Depends on: `gke` (remote state)
- Deploys:
  - `kube-prometheus-stack` v65.0.0 in `monitoring` namespace
  - Standalone `grafana` v10.5.15 in `monitoring` namespace
  - `loki` v6.23.0 in `monitoring` namespace
  - `promtail` v6.16.6 in `monitoring` namespace

### 2.3 Cloud Resources Inventory

**Compute**
- GKE Standard cluster `cinemates-dev` (zone: `us-east1-b`, k8s 1.33)
- Node pool `cinemates-nodepool-1`: 2 × e2-standard-2 preemptible, 50Gi pd-standard
- Node pool `cinemates-nodepool-2`: 1 × e2-standard-2 on-demand, 50Gi pd-standard
- NAP: auto-provisions nodes up to 50 vCPU / 128Gi RAM

**Networking**
- VPC `cinemates-vpc` (custom, global routing mode)
- Subnet `cinemates-gke-subnet` (10.0.0.0/24 nodes, secondary ranges for pods/services)
- Cloud Router `cinemates-gke-router` (BGP ASN 64514)
- Cloud NAT `cinemates-nat` (AUTO_ONLY, all subnetworks, error-only logging)
- GCP Global External HTTP Load Balancer (auto-provisioned by Gateway API controller)

**Security & Identity**
- Service account `github-actions-sa` — used by GitHub Actions to push images
- Service account `cinemates-dev-sa` — used by GKE nodes (logging, monitoring, artifact read)
- WIF pool `github-actions-pool` with OIDC provider `github-actions-provider`
- Secret Manager secret `dev-secret` (replicated us-east1 + us-west1)
- Secret Manager secret `GITHUB_PAT_ARGOCD_TOKEN` (read by gks-addons Terraform)
- Secret Manager secret `POSTGRES_DB_PASSWORD` (read by gks-addons Terraform)

**Storage**
- GCS bucket `cinemates-tf-state` (Terraform state, not managed in this repo — pre-existing)
- 10Gi PVC for Prometheus data (StorageClass: default cluster StorageClass)
- 10Gi PVC for Loki data

**Artifact Registry**
- `us-east1-docker.pkg.dev/cinemates-497209/cinemates-backend` (DOCKER format)
- `us-east1-docker.pkg.dev/cinemates-497209/cinemates-frontend` (DOCKER format)

### 2.4 State Management

State is stored in GCS bucket `cinemates-tf-state` with a separate prefix per module:

| Module | Prefix |
|--------|--------|
| vpc | `vpc` |
| gke | `gke` |
| iam | (not observed in tfvars; backend.tf present) |
| gsm | (not observed in tfvars) |
| gcr | (not observed in tfvars) |
| gks-addons | (uses GKE remote state for cluster credentials) |
| monitoring | (uses GKE remote state) |

GCS natively provides object-level locking for Terraform state. Each module is applied independently; cross-module outputs are shared via `terraform_remote_state` data sources keyed on workspace.

---

## 3. Application Layer

### 3.1 Services Overview

| Service | Runtime | Role | Container Port | Base Image |
|---------|---------|------|---------------|-----------|
| backend | Node.js 18 | REST API + WebSocket server | 8000 | node:18-alpine |
| frontend | nginx:alpine | React SPA static file server | 80 | nginx:alpine (runtime) |

### 3.2 Frontend — React SPA

- **Framework:** React 18.3, Vite 5.4, TailwindCSS 3.4, Radix UI component library
- **Notable dependencies:** react-router-dom 6 (client-side routing), @tanstack/react-query (data fetching/caching), socket.io-client (real-time chat), framer-motion (animations), three.js + @react-three/fiber (3D elements), zod + react-hook-form (form validation)
- **Build process (multi-stage):**
  1. Stage `build`: `node:18-alpine` — `npm ci`, `npm run build` (Vite emits to `/app/dist`). `VITE_BASE_URL` build arg bakes the backend API URL into the bundle.
  2. Stage runtime: `nginx:alpine` — copies `/app/dist` to `/usr/share/nginx/html`, uses custom `nginx.conf`
- **nginx configuration:** SPA fallback (`try_files $uri $uri/ /index.html`); 1-year immutable cache on `/assets/`
- **Key environment variables:** `VITE_BASE_URL` (baked at build time via Docker ARG), `VITE_REACT_APP_BACKEND_BASEURL` (used by Vite dev server proxy only), `VITE_MODE`
- **Health check:** HTTP GET `/` on port 80 (nginx always serves 200)
- **Secrets at runtime:** Kubernetes Secret `frontend-env` mounted via `envFrom` (contents not defined in this repo)

### 3.3 Backend — Express + Socket.io API

- **Framework:** Express 4.19, Node.js 18
- **Key dependencies:**

| Package | Purpose |
|---------|---------|
| mongoose 8.4 | MongoDB ODM |
| socket.io 4.8 | WebSocket/real-time chat |
| jsonwebtoken 9.0 | JWT auth (cookie-based) |
| bcryptjs 2.4 | Password hashing |
| cloudinary 1.21 | Image/media upload storage |
| cookie-parser 1.4 | Cookie parsing for JWT |
| morgan 1.10 | HTTP request logging |
| dotenv 16.4 | Environment variable loading |

- **API surface shape (REST, prefix `/api`):**
  - `/api/auth` — login, register, logout
  - `/api/users` — profile CRUD, follow/unfollow
  - `/api/posts` — social feed posts
  - `/api/collabs` — collaboration requests
  - `/api/ads` — advertisement listings
  - `/api/notifications` — user notifications
  - `/api/roh` — (Roh domain, purpose inferred: industry-specific content)
  - `/api/onboarding` — new user onboarding flow
  - `/api/filters` — feed/search filters
  - `/api/chat` — chat room management
  - `/api/message` — individual message CRUD
- **WebSocket (Socket.io) events:** `setup` (join user room), `join chat` (join room), `new message` (broadcast to chat participants), `typing` / `stop typing`, `user online` / `user offline` / `user status`
- **External connections:** MongoDB Atlas (via `MONGO_URI` env var, pool size 5–10), Cloudinary (via `CLOUDINARY_*` env vars)
- **Health check:** HTTP GET `/` returns 200 `OK` (explicit GCP LB health check route in `index.js`)
- **Authentication:** JWT stored in `jwt` httpOnly cookie; `protectRoute` middleware validates on protected routes
- **Key environment variables (all from Kubernetes Secret `backend-env`):** `MONGO_URI`, `JWT_SECRET`, `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`, `PORT`
- **CORS in production:** Hardcoded to `https://cinemates-brown.vercel.app` (see Gap #1)

### 3.4 Container Build Details

**backend:**
- Single stage: `node:18-alpine`
- `npm ci --omit=dev` installs only production dependencies from lockfile
- Runs as non-root user `node` (built into the node:18-alpine image)
- Exposes port 8000
- `.dockerignore` present at repo root (excludes `.env`)

**frontend:**
- Stage 1 (`build`): `node:18-alpine` — full dev dependencies installed, Vite build executed
- Stage 2 (runtime): `nginx:alpine` — only the compiled `/dist` assets and custom `nginx.conf` are copied
- Final image contains no Node.js, no source code, no dev dependencies
- nginx runs as root (default nginx image behavior; no USER directive in Dockerfile)
- Exposes port 80

---

## 4. Kubernetes / GitOps Layer

### 4.1 Cluster Configuration

| Attribute | Value |
|-----------|-------|
| Cluster name | `cinemates-dev` |
| Mode | Standard (manual node pool management) |
| Location | Zone: `us-east1-b` |
| Kubernetes version | 1.33 |
| CNI | Dataplane v2 (Cilium eBPF, `ADVANCED_DATAPATH`) |
| Gateway API | `CHANNEL_STANDARD` (built-in GKE controller) |
| NAP | Enabled (CPU 1–50, Memory 4–128Gi) |

**Node Pools:**

| Pool | Count | Machine | Preemptible | Disk |
|------|-------|---------|-------------|------|
| `cinemates-nodepool-1` | 2 | e2-standard-2 | yes | 50Gi pd-standard |
| `cinemates-nodepool-2` | 1 | e2-standard-2 | no | 50Gi pd-standard |

### 4.2 Namespace Map

| Namespace | Workloads | Purpose |
|-----------|-----------|---------|
| `default` | `cinemates-gateway` (Gateway resource) | Shared gateway |
| `dev` | `backend`, `frontend` | Application workloads |
| `argocd` | ArgoCD server, controller, repo-server, dex, redis | GitOps controller |
| `keda` | KEDA operator, metrics server, webhooks | Event-driven autoscaling |
| `database` | PostgreSQL primary | In-cluster database (currently unused by app) |
| `sonarqube` | SonarQube server | Code quality analysis |
| `monitoring` | Prometheus, Alertmanager, Grafana (×2), Loki, Promtail | Observability |

No explicit NetworkPolicy objects exist; traffic between namespaces is unrestricted.

### 4.3 GitOps Architecture

- **Tool:** ArgoCD v7.7.12
- **Pattern:** App of Apps
  - Root Application `root-app` lives in `argocd` namespace, source path `argo-apps/`
  - `argo-apps/` contains three child Application manifests: `backend.yaml`, `frontend.yaml`, `gateway.yaml`
  - Each child points to the corresponding Helm chart in `helm-charts/`
- **Sync policy (all apps):** `automated: { prune: true, selfHeal: true, allowEmpty: false }`
  - `prune: true` — resources deleted from Git are deleted from the cluster
  - `selfHeal: true` — manual out-of-band changes to the cluster are reverted
- **Source of truth:** `https://github.com/tenex-ai/gcp-tf-infra.git`, branch `HEAD` (**NOTE:** this URL is a stale reference — see Gap #2)
- **GitOps loop:** CI writes new image tag → ArgoCD detects values.yaml change → deploys within ArgoCD's reconciliation window (default 180s)

### 4.4 Application Manifests (Helm)

**Chart: `helm-charts/backend/`** (v0.1.0)

| Parameter | Value |
|-----------|-------|
| Replicas | 1 |
| Image | `us-east1-docker.pkg.dev/cinemates-497209/cinemates-backend/backend` |
| Tag | Updated by CI (current: `main-f67b85b4-14`) |
| Container port | 8000 (named `http`) |
| Service | ClusterIP, port 80 → 8000 |
| Liveness probe | TCP socket on port `http` |
| Readiness probe | HTTP GET `/` on port `http` |
| Env | `envFrom: secretRef: backend-env` |
| Objects produced | Deployment, Service, HTTPRoute |
| HTTPRoute rule | `PathPrefix /api` → backend service port 80 |
| Resource limits | **Not set** (see Gap #4) |
| securityContext | **Not set** (see Gap #5) |

**Chart: `helm-charts/frontend/`** (v0.1.0)

| Parameter | Value |
|-----------|-------|
| Replicas | 1 |
| Image | `us-east1-docker.pkg.dev/cinemates-497209/cinemates-frontend/frontend` |
| Tag | Updated by CI (current: `main-f67b85b4-14`) |
| Container port | 80 (named `http`) |
| Service | ClusterIP, port 80 → 80 |
| Liveness probe | HTTP GET `/` on port `http` |
| Readiness probe | HTTP GET `/` on port `http` |
| Env | `envFrom: secretRef: frontend-env` |
| Objects produced | Deployment, Service, HTTPRoute |
| HTTPRoute rule | `PathPrefix /` → frontend service port 80 |
| Resource limits | **Not set** (see Gap #4) |

**Chart: `helm-charts/gateway/`** (v0.1.0)

| Parameter | Value |
|-----------|-------|
| Gateway name | `cinemates-gateway` |
| Namespace | `default` |
| GatewayClass | `gke-l7-gxlb` (GKE Global External HTTP Load Balancer) |
| Listener | HTTP on port 80 |
| AllowedRoutes | `namespaces: from: All` (routes from any namespace) |

### 4.5 Managed Tools via GitOps

Tools deployed via Terraform (not through ArgoCD App of Apps):

| Tool | Namespace | Chart | Version | Key Config |
|------|-----------|-------|---------|-----------|
| ArgoCD | argocd | argo-cd | 7.7.12 | `server.insecure: true` (TLS terminated at Gateway) |
| KEDA | keda | keda | 2.20.0 | Default values, no ScaledObjects defined |
| PostgreSQL | database | postgresql (Bitnami) | 15.5.0 | Password from GSM `POSTGRES_DB_PASSWORD` |
| SonarQube | sonarqube | sonarqube | 2026.3.1 | Default values, accessible via port-forward |
| kube-prometheus-stack | monitoring | kube-prometheus-stack | 65.0.0 | 7d retention, 10Gi PVC |
| Grafana (standalone) | monitoring | grafana | 10.5.15 | No datasources provisioned |
| Loki | monitoring | loki | 6.23.0 | SingleBinary, filesystem storage |
| Promtail | monitoring | promtail | 6.16.6 | Ships to `loki:3100` |

---

## 5. Networking & Traffic Flow

### 5.1 Ingress Strategy

The cluster uses **Kubernetes Gateway API** (not Ingress). GKE's built-in Gateway controller manages the lifecycle of a GCP Global External HTTP Load Balancer based on the `Gateway` and `HTTPRoute` resources.

- **GatewayClass:** `gke-l7-gxlb` — provisions a GCP Global External Application Load Balancer
- **Gateway resource:** `cinemates-gateway` in `default` namespace, HTTP listener on port 80, allows routes from all namespaces
- **HTTPRoute — backend:** `PathPrefix /api` → `backend` service (port 80) in `dev` namespace
- **HTTPRoute — frontend:** `PathPrefix /` → `frontend` service (port 80) in `dev` namespace

The `/api` route has higher specificity and is matched first; all other traffic falls through to the frontend.

There is no HTTPS listener. TLS termination is not configured (see Gap #6).

### 5.2 Traffic Path (end-to-end)

```
User (Browser)
  │
  ▼ DNS resolution (not managed in this repo — external DNS)
GCP Global External HTTP Load Balancer
  │  (auto-provisioned by GKE Gateway controller)
  │
  ▼ HTTP :80
Gateway API Controller (GKE built-in, running in kube-system)
  │
  ├── Path /api/* ──────────────────────────────────────────────────────►
  │                                                                       │
  │                                                              backend Service (ClusterIP :80)
  │                                                                       │
  │                                                              backend Pod (:8000)
  │                                                                       │
  │                                                              MongoDB Atlas (via Cloud NAT)
  │                                                              Cloudinary (via Cloud NAT)
  │
  └── Path /* ─────────────────────────────────────────────────────────►
                                                                         │
                                                                frontend Service (ClusterIP :80)
                                                                         │
                                                                frontend Pod / nginx (:80)
                                                                (serves static assets from /dist)

WebSocket (Socket.io) upgrade:
  Browser → Load Balancer → Gateway → backend Pod (Socket.io upgrades HTTP → WS on same connection)
```

Internal service DNS: `backend.<namespace>.svc.cluster.local:80`, `frontend.<namespace>.svc.cluster.local:80`.

### 5.3 TLS Configuration

**TLS is not configured.** The Gateway listens on HTTP port 80 only. There is no cert-manager installation, no ClusterIssuer, and no HTTPS listener in the Gateway resource. All traffic — including authentication cookies and JWT tokens — travels unencrypted between the load balancer and clients.

### 5.4 Internal Service Communication

- Frontend pod (nginx) serves static assets; there is no server-side proxy to the backend from inside the cluster. The browser makes direct API calls to the load balancer's external IP.
- Backend pods connect to MongoDB Atlas at the URI specified in `MONGO_URI` env var, egressing through Cloud NAT.
- Backend pods connect to Cloudinary's CDN API, also through Cloud NAT.
- ArgoCD accesses GitHub via HTTPS (PAT stored in `GITHUB_PAT_ARGOCD_TOKEN` secret in GSM, injected as a Kubernetes Secret at Terraform apply time).

---

## 6. CI/CD Pipeline

### 6.1 Pipeline Overview

```
Push to main branch (paths: backend/**, helm-charts/**, .github/workflows/**)
  │
  ▼
GitHub Actions: backend-pipeline.yaml
  [1] Authenticate to GCP via Workload Identity Federation (no SA key)
  [2] Extract metadata: BRANCH_NAME, SHORT_SHA (8 chars), RUN_NUMBER
  [3] gcloud auth configure-docker us-east1-docker.pkg.dev
  [4] Build Docker image (context: repo root, dockerfile: backend/Dockerfile)
  [5] Push to Artifact Registry: tags `latest` AND `{branch}-{sha8}-{run_number}`
  [6] (Job 2, push to main only) Install yq
  [7] Update helm-charts/backend/values.yaml: .image.tag = "{tag}"
  [8] git commit "chore: update backend image tag to {tag} [skip ci]"
  [9] git push origin HEAD:main (with up to 5 pull-rebase retries)
  │
  ▼
ArgoCD polls repository (reconciliation interval: 180s)
  │
  ▼
ArgoCD detects values.yaml change → syncs backend Application
  │
  ▼
GKE pulls new image from Artifact Registry → rolling update
```

Same pattern applies to `frontend-pipeline.yaml` for frontend changes.

### 6.2 Workflow Inventory

| Workflow | Trigger | Jobs | Secrets Used |
|----------|---------|------|--------------|
| `backend-pipeline.yaml` | push/PR to main (paths: backend/**, helm-charts/**, workflows/**); workflow_dispatch | `build-and-push-to-gcr`, `update-helm-values` | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |
| `frontend-pipeline.yaml` | push/PR to main (paths: frontend/**, helm-charts/**, workflows/**); workflow_dispatch | `build-and-push-to-gcr`, `update-helm-values` | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT` |

### 6.3 Image Tagging Strategy

Format: `{branch_name}-{sha8}-{run_number}`

Example: `main-f67b85b4-14`

Additionally, `latest` is always pushed (though ArgoCD tracks the specific tag, not `latest`). Branch names have `/` replaced with `-`.

### 6.4 Deployment Gates

There are **no gates** before production deployment. Any push to `main` that changes the relevant paths triggers an immediate build and deploy. There are:
- No automated tests
- No image vulnerability scanning
- No manual approval step
- No staging environment

The `[skip ci]` tag on the automated helm-values commit prevents the CI loop from retriggering itself.

### 6.5 Rollback Strategy

Rollback is performed by reverting the relevant `helm-charts/*/values.yaml` commit in Git. ArgoCD detects the change and redeploys the previous image tag. There is no documented runbook for rollback. ArgoCD UI also allows manual image tag override without a Git commit, but this would be undone by the next `selfHeal` cycle.

---

## 7. Security Architecture

### 7.1 Secret Management

| Secret | Store | How it enters the cluster |
|--------|-------|--------------------------|
| `GITHUB_PAT_ARGOCD_TOKEN` | GCP Secret Manager | Read by Terraform at apply time; written as Kubernetes Secret `github-repo-creds` in `argocd` namespace |
| `POSTGRES_DB_PASSWORD` | GCP Secret Manager | Read by Terraform at apply time; passed as `set_sensitive` to Helm |
| `backend-env` | Kubernetes Secret (manual population) | `envFrom` in backend Deployment |
| `frontend-env` | Kubernetes Secret (manual population) | `envFrom` in frontend Deployment |
| `dev-secret` | GCP Secret Manager | Created by `infra/gsm/` module; not yet wired to pods |
| ArgoCD admin password | Kubernetes Secret `argocd-initial-admin-secret` | Auto-generated by ArgoCD on first run |

The README mentions External Secrets Operator (ESO) for syncing GSM secrets to Kubernetes Secrets, but **ESO is not deployed** in this repository. The `backend-env` and `frontend-env` secrets appear to be created manually.

### 7.2 Identity & Access

**Workload Identity Federation (WIF):**
- GitHub Actions authenticates to GCP using OIDC tokens from `token.actions.githubusercontent.com`
- WIF pool `github-actions-pool` / provider `github-actions-provider` validates the token
- Maps to service account `github-actions-sa`
- Grants: `roles/artifactregistry.writer` (allows pushing images)
- **Gap:** The `attribute_condition` in `infra/iam/tfvars/dev.tfvars` restricts to repo `tenex-ai/gcp-tf-infra` — this must be updated to the actual cinemates repository or WIF auth will fail.

**GKE Node Service Account (`cinemates-dev-sa`):**
- `roles/logging.logWriter` — write logs to Cloud Logging
- `roles/monitoring.metricWriter` — write metrics to Cloud Monitoring
- `roles/monitoring.viewer` — read monitoring data
- `roles/stackdriver.resourceMetadata.writer` — write resource metadata
- `roles/artifactregistry.reader` — pull images from Artifact Registry

No custom RBAC ClusterRoles or RoleBindings are defined in this repository for application workloads.

### 7.3 Network Security

- **NetworkPolicy:** None. All pods in all namespaces can communicate freely.
- **Egress:** GKE nodes use private IP addresses; outbound internet access (MongoDB Atlas, Cloudinary, GitHub, Docker Hub) goes through Cloud NAT.
- **Ingress:** Only port 80 is exposed externally via the GCP Load Balancer. There is no firewall rule explicitly blocking other ports — this is handled by GKE's default node firewall.

### 7.4 Container Security

| Workload | runAsNonRoot | readOnlyRootFilesystem | allowPrivilegeEscalation | Capabilities |
|----------|-------------|----------------------|--------------------------|--------------|
| backend | Yes (USER node in Dockerfile) | Not set in chart | Not set in chart | Not set in chart |
| frontend | No (nginx default runs as root) | Not set in chart | Not set in chart | Not set in chart |
| KEDA operator | Yes (chart default) | Yes (chart default) | false (chart default) | drop ALL |
| Grafana | Yes (runAsUser: 472) | — | false | drop ALL |
| ArgoCD controller | Yes | Yes | false | drop ALL |

The Helm chart templates for backend and frontend have no `securityContext` block. The containers rely on Dockerfile-level settings only.

### 7.5 Image Security

- **Backend base image:** `node:18-alpine` — official, but tag is floating (not pinned to digest)
- **Frontend build image:** `node:18-alpine` — same
- **Frontend runtime:** `nginx:alpine` — official, floating tag
- **Image scanning:** Not present in CI pipeline
- Images are tagged with a specific build tag (not `latest`) for the running workload, but `latest` is also pushed and could be pulled accidentally.

---

## 8. Observability Stack

### 8.1 Metrics

- **Tool:** `kube-prometheus-stack` v65.0.0 (includes Prometheus Operator, Prometheus, Alertmanager, kube-state-metrics, node-exporter, and an embedded Grafana)
- **Prometheus retention:** 7 days
- **Storage:** 10Gi PVC (`ReadWriteOnce`)
- **Resources:** requests 200m CPU / 512Mi RAM, limits 1 CPU / 1Gi RAM
- **ServiceMonitor/PrometheusRule:** None defined for application workloads. Kubernetes infrastructure metrics (nodes, pods, kube-state) are scraped by default via the prometheus-stack.
- **Alertmanager resources:** 50m/128Mi requests, 200m/256Mi limits
- **Grafana datasource wiring:** The `kube-prometheus-stack`'s embedded Grafana has Prometheus auto-configured as a datasource. The standalone `grafana` chart deployment has **no datasources provisioned** in its `values.yaml`.

### 8.2 Logging

- **Collection:** Promtail v6.16.6 deployed as a DaemonSet, scrapes container logs from each node
- **Aggregation:** Loki v6.23.0 in `SingleBinary` mode; Promtail ships to `http://loki:3100/loki/api/v1/push`
- **Storage:** Filesystem (10Gi PVC). Not object-backed — log data is lost if the Loki PVC is deleted.
- **Retention:** Not explicitly configured (Loki default)
- **Log format:** Not enforced; application code uses `console.log` (unstructured text)
- **Grafana-Loki integration:** Not wired up in the standalone Grafana values.

### 8.3 Tracing

No distributed tracing is configured. Neither OpenTelemetry SDK nor a tracing backend (Tempo, Jaeger) is present.

### 8.4 Alerting

No PrometheusRule objects or AlertmanagerConfig resources are defined. The Alertmanager is deployed but has no alert rules. No notification channels (Slack, PagerDuty, email) are configured.

### 8.5 Dashboards

The `kube-prometheus-stack` deploys a set of default Kubernetes infrastructure dashboards in its embedded Grafana (node, pod, namespace panels). No custom application dashboards are provisioned. The standalone Grafana deployment has no dashboards configured.

---

## 9. Autoscaling

### 9.1 Pod Scaling

No HPA or KEDA ScaledObjects are configured for backend or frontend workloads. Both deployments run at a fixed `replicaCount: 1`.

### 9.2 Node Scaling

**Node Auto-Provisioning (NAP)** is enabled on the cluster alongside explicit node pools:
- Upper bounds: 50 vCPU, 128Gi memory (cluster-wide across all auto-provisioned pools)
- Auto-provisioned nodes use the `cinemates-dev-sa` service account with `cloud-platform` scope
- `auto_repair: true`, `auto_upgrade: true`
- Existing node pools also benefit from GKE cluster autoscaler behavior when NAP is active.

### 9.3 ScaledObject Details

KEDA v2.20.0 is installed and ready in the `keda` namespace. No ScaledObjects are defined. KEDA is pre-deployed in anticipation of scaling backend pods based on custom metrics (e.g., WebSocket connection count), but this is not yet implemented.

---

## 10. Local Development

### 10.1 Prerequisites

- Node.js 18+
- Docker Desktop
- `kubectl` + `gcloud` CLI (for cluster access)
- Terraform 1.x (for infra changes)

### 10.2 Getting Started

There is no `docker-compose.yml` or `Makefile` in the repository. To run locally:

**Frontend:**
```bash
cd frontend
cp .env .env.local  # .env already contains localhost backend URL
npm install
npm run dev         # Vite dev server on :3000, proxies /api to localhost:8000
```

**Backend:**
```bash
cd backend
# Create backend/.env with MONGO_URI, JWT_SECRET, CLOUDINARY_* values
npm install
npm run dev         # nodemon on :8000
```

There is no one-command local stack. No docker-compose is provided; running against a local MongoDB would require a separate MongoDB instance.

### 10.3 Environment Configuration

**Frontend** (`frontend/.env`):
```
VITE_REACT_APP_BACKEND_BASEURL=http://localhost:8000
VITE_MODE=development
VITE_BASE_URL=""
```

**Backend** (`.env` file, not committed — `.dockerignore` excludes it):
Required: `MONGO_URI`, `JWT_SECRET`, `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`, `PORT` (defaults to 8000)

---

## 11. Data Architecture

### 11.1 Databases

| Database | Type | Hosting | Connection |
|----------|------|---------|-----------|
| MongoDB | Document DB | MongoDB Atlas (external managed SaaS) | `MONGO_URI` env var, pool 5–10 connections |
| PostgreSQL | Relational | In-cluster (Bitnami chart, `database` namespace) | `POSTGRES_DB_PASSWORD` from GSM — **not used by application** |

MongoDB connection options: `serverSelectionTimeoutMS: 30000`, `socketTimeoutMS: 45000`, `retryWrites: true`, `retryReads: true`. Automatic reconnect on disconnect via event listeners + server-level retry in `startServer()`.

### 11.2 Data Flow

```
Client → HTTPS/WSS → Load Balancer → Gateway → Backend Pod
                                                    │
                                    ┌───────────────┤
                                    │               │
                              MongoDB Atlas    Cloudinary
                              (user data,      (media files,
                               posts, chats)    images)
                                    │
                              Data returned to Backend
                                    │
                              JSON response → Client
```

### 11.3 Backup & Recovery

**MongoDB Atlas:** Backup is managed by MongoDB Atlas (not by this repository). Atlas provides continuous backup and point-in-time recovery by default on paid tiers. No backup configuration is defined here.

**PostgreSQL (in-cluster):** The Bitnami chart does not have persistence configured with a dedicated backup strategy. No backup for the in-cluster PostgreSQL is defined.

**Cluster state (Kubernetes resources):** No Velero or equivalent cluster backup tool is installed. A cluster loss would require re-running Terraform and re-syncing ArgoCD.

---

## 12. Architecture Decisions & Rationale

**Decision: Mixed monorepo (app + infra in one repo)**
Rationale: Simplifies the GitOps image-tag update loop — CI can commit to `helm-charts/` and ArgoCD watches the same repo. No cross-repo coordination needed.
Trade-off: App and infrastructure release cycles are coupled. A backend code change and an infrastructure change can conflict in the same merge.

**Decision: Gateway API over Ingress**
Rationale: Gateway API is the Kubernetes-native successor to Ingress. GKE's `gke-l7-gxlb` GatewayClass provisions a true global external load balancer with richer routing semantics. The `allowedRoutes: from: All` configuration allows HTTPRoutes in the `dev` namespace to attach to a Gateway in `default`.
Trade-off: Gateway API v1beta1 objects require a more recent Kubernetes version and GKE-specific GatewayClass knowledge. Debugging is slightly harder than Ingress annotations.

**Decision: GitOps image-tag commit loop (CI writes to repo)**
Rationale: Keeps the Git repository as the single source of truth for what is running in the cluster. ArgoCD reconciles declaratively rather than imperatively. Enables easy rollback (git revert).
Trade-off: The CI pipeline requires `contents: write` permission to push back to the repo. A concurrent push from both CI jobs (backend and frontend) can cause git conflicts, which the retry-with-rebase logic mitigates but does not eliminate.

**Decision: Workload Identity Federation for CI (no SA key files)**
Rationale: Eliminates the need to store long-lived service account JSON keys as GitHub secrets. OIDC tokens are short-lived and tied to the specific GitHub workflow run.
Trade-off: Requires the WIF pool and provider to be correctly configured with the right `attribute_condition`. Misconfiguration silently breaks all CI deployments.

**Decision: Separate Terraform modules with independent state**
Rationale: Allows independent apply cycles. A networking change doesn't require re-planning the GKE cluster. Cross-module dependencies are explicit via `terraform_remote_state`.
Trade-off: More complex bootstrap ordering. Cannot do a single `terraform apply` for the whole stack.

**Decision: Preemptible nodes for the majority of workloads (nodepool-1, 2 nodes)**
Rationale: Cost reduction — preemptible/spot VMs are 60–80% cheaper than on-demand. Acceptable for stateless application pods that can be rescheduled.
Trade-off: Nodes can be preempted with 30s notice. Running only 1 replica per service means preemption causes a brief outage. A non-preemptible `nodepool-2` node exists for platform workloads (ArgoCD, Prometheus, etc.) to remain stable.

**Decision: Dataplane v2 (Cilium eBPF CNI)**
Rationale: Native to GKE, provides higher network throughput and lower latency than the legacy Kubenet CNI. Also required as a prerequisite if NetworkPolicy enforcement with identity-aware L4 filtering is introduced later.
Trade-off: Slightly more complex to debug than standard kube-proxy networking.

**Decision: KEDA installed but not yet used**
Rationale: Installed proactively so the CRDs and operator are already in place. The intent (per README) is to eventually scale backend pods based on WebSocket connection count.
Trade-off: KEDA operator consumes ~100m CPU / 100Mi RAM with no immediate benefit until ScaledObjects are defined.

---

## 13. Known Gaps & Recommendations

**Gap: ArgoCD repo URL and WIF condition reference wrong GitHub repository**
Risk: ArgoCD cannot pull manifests from `tenex-ai/gcp-tf-infra.git` (stale repo name). GitHub Actions WIF authentication will fail if the attribute condition isn't updated. The entire CD pipeline is broken in a fresh deployment until these are corrected.
Recommendation: Update `infra/gks-addons/charts/argo-root-app/root-app.yaml`, `argo-apps/*.yaml`, `infra/gks-addons/argocd.tf` (kubernetes_secret data URL), and `infra/iam/tfvars/dev.tfvars` (attribute_condition) to reference the correct repository name.

**Gap: Backend CORS hardcoded to Vercel URL**
Risk: Browser requests from the GKE-hosted frontend (different domain) will be blocked by CORS policy. Real-time Socket.io connections will also fail.
Recommendation: Replace the hardcoded `https://cinemates-brown.vercel.app` in `backend/index.js` with an environment variable (`ALLOWED_ORIGIN`) and set it correctly in the `backend-env` Kubernetes Secret.

**Gap: No TLS / HTTPS**
Risk: All user traffic (including authentication cookies containing JWT tokens) is transmitted in plaintext. Authentication cookies cannot use `Secure` flag. This is a critical security exposure.
Recommendation: Deploy cert-manager, create a `ClusterIssuer` using Let's Encrypt, and add an HTTPS listener to the Gateway with an attached certificate. Update ArgoCD HTTPRoute for ArgoCD UI access to also use HTTPS.

**Gap: No resource limits or requests on application pods**
Risk: A backend memory leak or traffic spike can consume all node resources, evicting other pods including monitoring and ArgoCD. The cluster scheduler cannot make optimal placement decisions without resource declarations.
Recommendation: Add `resources.requests` and `resources.limits` to `helm-charts/backend/values.yaml` and `helm-charts/frontend/values.yaml`. Reasonable starting point: backend 200m/256Mi requests, 500m/512Mi limits; frontend 50m/64Mi requests, 100m/128Mi limits.

**Gap: No securityContext on application Helm charts**
Risk: Backend and frontend containers have no hardened security posture at the Kubernetes level (no `allowPrivilegeEscalation: false`, no `capabilities: drop: ALL`, no `readOnlyRootFilesystem`).
Recommendation: Add `securityContext` blocks to the deployment templates. Backend can set `runAsNonRoot: true` (already non-root via Dockerfile). Frontend nginx requires write access to `/tmp` and `/var/cache/nginx` — use `readOnlyRootFilesystem: true` with emptyDir volume mounts for those paths.

**Gap: No NetworkPolicy**
Risk: Any compromised pod in the cluster can freely communicate with any other pod, including the database namespace and monitoring stack.
Recommendation: Start with a default-deny policy in the `dev` namespace and add explicit allow rules for backend → MongoDB (egress), Gateway controller → backend/frontend (ingress), Prometheus → pods with scrape annotations (ingress).

**Gap: No automated tests or image scanning in CI**
Risk: Code regressions and known vulnerabilities ship to production without any automated check. The `package.json` test script is `exit 1` (placeholder).
Recommendation: Add a unit test stage before the Docker build step. Add Trivy image scanning after the push step with a configurable severity threshold for failures.

**Gap: Duplicate Grafana instances**
Risk: `kube-prometheus-stack` deploys its own Grafana instance with Prometheus auto-wired. The standalone `grafana` chart deployment is also present with no datasources, creating confusion about which to use and wasting resources.
Recommendation: Disable the embedded Grafana in the kube-prometheus-stack values (`grafana.enabled: false`) and configure datasources in the standalone Grafana chart, or remove the standalone chart and use only the stack's embedded instance.

**Gap: Grafana Loki datasource not wired up**
Risk: Promtail is shipping logs to Loki, but Grafana has no Loki datasource configured. Logs are being collected but cannot be queried.
Recommendation: Add a Loki datasource to the Grafana `datasources` section in its values file pointing to `http://loki:3100`.

**Gap: Loki using filesystem storage**
Risk: Loki's `SingleBinary` mode with `storage.type: filesystem` stores all log data on a single PVC. If the PVC is deleted or the pod is replaced on a different node without the PVC migrating, all historical logs are lost. This is explicitly marked as `deploymentMode: SingleBinary` for dev/test in the values comment.
Recommendation: For any production usage, switch to an object storage backend (GCS). Create a GCS bucket for Loki and configure `storage.type: gcs` with Workload Identity for authentication.

**Gap: No External Secrets Operator (ESO)**
Risk: The README describes ESO as part of the architecture, but it is not deployed. The `backend-env` and `frontend-env` secrets must be created manually. There is no automated sync from Google Secret Manager to Kubernetes Secrets.
Recommendation: Deploy ESO and define `ExternalSecret` objects that sync the relevant GSM secrets to Kubernetes Secrets in the `dev` namespace.

**Gap: PostgreSQL in-cluster with no application connection**
Risk: PostgreSQL is deployed and consuming resources (CPU, memory, storage, GSM secret) but no application code connects to it. MongoDB Atlas is the actual database.
Recommendation: Either wire PostgreSQL to an actual use case (e.g., SonarQube DB, analytics sidecar) or remove it to reduce cost and operational overhead.

**Gap: No alert rules defined**
Risk: Prometheus and Alertmanager are deployed but completely silent. Pod crashes, node pressure, high latency, and MongoDB connectivity failures generate no alerts.
Recommendation: Define PrometheusRule resources for at minimum: pod restart rate, deployment unavailable replicas, node CPU/memory pressure, and a dead-man's switch alert.

---

## 14. Dependency Graph

```
[GitHub Repo]
    │
    ├──push────────────────────────────────────────────────────────────────────┐
    │                                                                           │
    ▼                                                                           │
[GitHub Actions CI]                                                             │
    │                                                                           │
    ├─ auth via ──► [WIF Pool] ──► [github-actions-sa]                         │
    │                                                                           │
    ├─ build ─────────────────────► [GCP Artifact Registry]                    │
    │                                    ▲                                      │
    │                                    │ pull images                          │
    │                                    │                                      │
    └─ commit tag ──► [helm-charts/*/values.yaml] ──────────────────────────────┘
                                         │
                                         │ (same repo, HEAD)
                                         ▼
                                   [ArgoCD] ─── watches ──► [GitHub Repo: argo-apps/]
                                         │
                                         │ reconciles
                                         ▼
                                   [GKE Cluster] (us-east1-b)
                                    │
                                    ├── [GCP Load Balancer] ◄─── user HTTPS/WS traffic
                                    │         │
                                    │         ▼ (HTTP :80)
                                    │   [Gateway API Controller]
                                    │         │
                                    │   ┌─────┴──────┐
                                    │   │            │
                                    │   ▼            ▼
                                    │ [frontend]  [backend] ──► [MongoDB Atlas]
                                    │  (nginx)   (Node.js)  ──► [Cloudinary]
                                    │
                                    ├── [ArgoCD] ◄──────────────── [GitHub Repo]
                                    │
                                    ├── [KEDA] (installed, no ScaledObjects)
                                    │
                                    ├── [kube-prometheus-stack]
                                    │     ├── [Prometheus] ◄── scrapes cluster metrics
                                    │     ├── [Alertmanager] (no rules)
                                    │     └── [Grafana] (k8s dashboards)
                                    │
                                    ├── [Loki] ◄── [Promtail DaemonSet]
                                    │     (logs not wired to Grafana)
                                    │
                                    ├── [Grafana standalone] (no datasources)
                                    │
                                    ├── [PostgreSQL] (unused by app)
                                    │
                                    └── [SonarQube] (not in CI)
                                    
[Terraform] ──── provisions ────────► [GCP VPC + Subnets + Cloud NAT]
                                       [GKE Cluster + Node Pools]
                                       [IAM + WIF]
                                       [Artifact Registry repos]
                                       [Secret Manager secrets]
                                       [Helm releases: ArgoCD, KEDA, monitoring, etc.]
```

---

## 15. Glossary

| Term | Definition |
|------|-----------|
| **NAP** | Node Auto-Provisioning — GKE feature that automatically creates new node pools to satisfy unschedulable pods, within configured resource limits |
| **Dataplane v2** | GKE's eBPF-based CNI (powered by Cilium), enabled via `ADVANCED_DATAPATH`. Replaces iptables-based kube-proxy for packet processing |
| **WIF** | Workload Identity Federation — allows GitHub Actions (or other external workloads) to authenticate to GCP using OIDC tokens without storing long-lived service account keys |
| **App of Apps** | ArgoCD pattern where a "root" Application manages a set of child Application manifests stored in Git. Adding a new app means committing one YAML file to the `argo-apps/` directory |
| **gke-l7-gxlb** | GatewayClass name for GKE's Global External HTTP(S) Load Balancer. Provisions a GCP Global HTTPS LB that terminates connections at Google's edge PoPs |
| **GitOps tag loop** | The automated process where CI pushes a new image tag to Artifact Registry, commits the tag into `helm-charts/*/values.yaml`, and ArgoCD picks up the commit and deploys the new image |
| **ESO** | External Secrets Operator — a Kubernetes operator that syncs secrets from external stores (like GCP Secret Manager) into Kubernetes Secret objects. Referenced in the README but not yet deployed |
| **KEDA** | Kubernetes Event-Driven Autoscaler — scales workloads based on external metrics (queue depth, WebSocket connections, HTTP request rate, etc.) rather than just CPU/memory |
| **Roh** | Internal domain term used in backend routes (`/api/roh`) and models (`RohModel`). Context-specific to the Cinemates platform; likely refers to a feature area |
| **[skip ci]** | Git commit message tag that prevents GitHub Actions from triggering a new workflow run on the automated helm-values commit, avoiding an infinite CI loop |
