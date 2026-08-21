# argo.kiitconsulting.com

GitOps source of truth for the Argo CD instance at
**<https://argo.kiitconsulting.com>** — a single-node k3s cluster on the Hetzner
`k3s-argocd` host. Everything Argo CD runs on that cluster is declared in this
repo. **You deploy by `git push`, not by `kubectl apply`:** Argo CD continuously
reconciles the cluster to match `main` (auto-sync, self-heal, prune).

> The cluster/host itself (k3s, Traefik, cert-manager, Argo CD, firewall) is
> provisioned separately in
> [`ikscream/ai-hetzner`](https://github.com/ikscream/ai-hetzner) under
> `provisioning/`. This repo is only the **workloads** Argo CD deploys.

## Live endpoints

| URL | What | Namespace |
|---|---|---|
| <https://argo.kiitconsulting.com> | Argo CD UI | `argocd` |
| <https://grafana-k8s.kiitconsulting.com> | Grafana (kube-prometheus-stack) | `monitoring` |
| <https://registry.kiitconsulting.com> | S3-backed container registry (basic-auth) | `registry` |
| <https://echo.kiitconsulting.com> | example app — JSON request echo | `echo` |
| <https://podinfo.kiitconsulting.com> | example app — podinfo | `demo` |
| <https://bayes-ingest.kiitconsulting.com> | bayes.markets `ingest` — the BTC tape collector: dependency status, lease holder, rows written | `bayes` |
| <https://ap.kiitconsulting.com> | ai-portal v2 — Claude Code control plane / UI (Cloudflare Access SSO) | `ai-portal` |

## Architecture

```
bootstrap/root-app.yaml ──▶ apps/*.yaml (child Applications) ──▶ manifests/<app>/… ──▶ cluster
   (app-of-apps root)          (one Application per app)          (Kustomize resources)

CI (GitHub Actions) ──build──▶ registry.kiitconsulting.com ──blobs──▶ Hetzner S3 (bucket kiit-registry)
        └── writes image tag back to manifests/echo ──▶ Argo CD deploys
```

- **App-of-apps:** `bootstrap/root-app.yaml` is a single Argo CD `Application`
  that watches [`apps/`](./apps) recursively. Every `Application` there is created
  and reconciled automatically — add one, `git push`, done.
- **In-cluster target:** all Applications deploy to `https://kubernetes.default.svc`
  (the cluster Argo CD runs on, registered as `in-cluster`).
- **TLS + DNS:** each public app has a Traefik `Ingress` with a
  `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation + a `tls` block;
  cert-manager issues a real Let's Encrypt cert via **HTTP-01**. Each hostname
  needs a **DNS-only** (grey-cloud) Cloudflare A record at the node IP.
- **Registry:** an in-cluster `registry:3` whose S3 storage driver writes image
  blobs into Hetzner Object Storage. See [`docs/ci-cd.md`](./docs/ci-cd.md).

## Repository layout

| Path | Purpose |
|---|---|
| `bootstrap/root-app.yaml` | App-of-apps root Application (one-time bootstrap). |
| `apps/*.yaml` | One Argo CD `Application` per workload; watched recursively by root. |
| `manifests/<app>/` | Kubernetes resources per app (Kustomize). `echo`, `podinfo`, `registry`, `bayes-markets`. |
| `apps/monitoring.yaml` | Helm-source app: Prometheus Operator + Grafana ([`docs/monitoring.md`](./docs/monitoring.md)). |
| `examples/echo/` | Example app **source** (Go stdlib) + `Dockerfile`, built by CI. |
| `.github/workflows/echo.yml` | CI: build image → push to the S3-backed registry → write tag back. |
| `manifests/bayes-markets/` | PostgreSQL + Redis + `ingest` for **bayes.markets**. Source and CI live in [`ikscream/prj-bayes-markets`](https://github.com/ikscream/prj-bayes-markets) (`services/ingest`), which writes the image tag here. |
| `docs/` | [`adding-an-application.md`](./docs/adding-an-application.md), [`ci-cd.md`](./docs/ci-cd.md). |
| `README.md` / `CLAUDE.md` / `MEMORY.md` | Human overview / agent operating manual / durable project memory. |

## Prerequisites

You do not set up a cluster from this repo. It assumes a running cluster that
already has **Argo CD**, **Traefik** (k3s default ingress), **cert-manager** with
a `letsencrypt-prod` ClusterIssuer, and the registry Secrets (below). All of that
is stood up by `ai-hetzner/provisioning/`.

To interact with the cluster you need SSH to the host (`root@178.104.210.183`,
key `op://ai-skills/ssh-k3s-argocd`) and `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
there — the Kubernetes API (6443) is firewalled off, so `kubectl` runs on the box.

## Bootstrap (one-time; already done for this cluster)

```sh
kubectl apply -f https://raw.githubusercontent.com/ikscream/argo.kiitconsulting.com/main/bootstrap/root-app.yaml
```

That is the only imperative step. Verify:

```sh
kubectl -n argocd get applications
# NAME       SYNC     HEALTH
# root       Synced   Healthy
# echo       Synced   Healthy
# podinfo    Synced   Healthy
# registry   Synced   Healthy
```

## Deploy / add an application

Add `manifests/<name>/` (with a `kustomization.yaml`) and `apps/<name>.yaml`
(copy an existing one, adjust `name`, `source.path`, `destination.namespace`),
then `git push`. Argo CD syncs within ~3 min (its default poll) or immediately on
a **Refresh** in the UI. Full guide:
[`docs/adding-an-application.md`](./docs/adding-an-application.md).

## Build & test the example `echo` app

`examples/echo` is a tiny stdlib Go HTTP server that returns JSON describing the
request (requested `host`/DNS name, `client_ip`, method, path, headers, serving
pod). Endpoints: `/` (echo), `/healthz`, `/readyz`. Listens on `:8080`.

```sh
cd examples/echo
go vet ./... && go build ./...        # verify it compiles
go run .                              # then, in another shell:
curl -s localhost:8080/hello?x=1 | jq

# container build (what CI does):
docker build -t echo:dev .            # multi-stage -> distroless, non-root
```

Validate any app's manifests before pushing:

```sh
kubectl kustomize manifests/echo      # (or podinfo / registry)
```

## Configuration & environment variables

| Where | Variable | Purpose | Source |
|---|---|---|---|
| `echo` container | `LISTEN_ADDR` | Override listen address (default `:8080`). | optional env |
| `registry` container | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | S3 driver creds. | Secret `registry-s3` (from `op://ai-skills/hetzner/s3`) |
| `registry` container | `AWS_REGION` | `fsn1`. | literal env |
| GitHub Actions | `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | Push to the registry. | repo secrets (from `op://ai-skills/registry-kiit`) |

Registry storage (bucket `kiit-registry`, endpoint `https://fsn1.your-objectstorage.com`)
is set in [`manifests/registry/configmap.yaml`](./manifests/registry/configmap.yaml).

### Secrets are NOT in git

`registry-s3` + `registry-auth` (namespace `registry`) and `registry-pull`
(namespace `echo`) are created **out-of-band** from 1Password — never committed.
Bootstrap commands are in [`docs/ci-cd.md`](./docs/ci-cd.md).

## Sync policy & conventions

- **Automated sync**, `selfHeal: true` (reverts manual drift), `prune: true`
  (deletes resources removed from git), `CreateNamespace=true`.
- Applications carry `finalizers: [resources-finalizer.argocd.argoproj.io]` so
  deleting one cascades to its cluster resources.
- One namespace per app. Names usually match the app (`echo`, `registry`);
  `podinfo` is the exception — it deploys to `demo`.

## Making this repo private later

Public today, so Argo CD reads it anonymously. If made private, add repo
credentials to Argo CD (Settings → Repositories or a `repo-…` Secret) — a GitHub
deploy key or read PAT. Nothing else changes.
