# argo.kiitconsulting.com

GitOps source of truth for the Argo CD instance running at
**<https://argo.kiitconsulting.com>** (single-node k3s on the Hetzner `k3s-argocd`
host — provisioning lives in [`ikscream/ai-hetzner`](https://github.com/ikscream/ai-hetzner)
under `provisioning/`).

Everything Argo CD runs on that cluster is declared here. **You deploy by
`git push`, not by `kubectl apply`.** Argo CD continuously reconciles the cluster
to match this repo (auto-sync, self-heal, prune).

## How it works — app of apps

```
                 ┌──────────────────────── this repo ────────────────────────┐
bootstrap/root-app.yaml ──▶ apps/*.yaml (child Applications) ──▶ manifests/<app>/…
   (root Application)          (one Application per app)            (k8s resources)
        │                             │                                  │
        ▼                             ▼                                  ▼
   watches apps/              each watches its               plain/Kustomize manifests
   recursively                manifests/<app> path           synced into the cluster
```

- **`bootstrap/root-app.yaml`** — the *app of apps*. Applied once; it tells Argo
  CD to watch [`apps/`](./apps). Anything you add there is picked up automatically.
- **[`apps/`](./apps)** — one Argo CD `Application` per workload. These are the
  units you add/remove to deploy things.
- **[`manifests/`](./manifests)** — the actual Kubernetes YAML (Kustomize) each
  Application points at.

All Applications target the **in-cluster** endpoint
`https://kubernetes.default.svc` — i.e. Argo CD manages the very cluster it runs
on (registered in Argo CD as `in-cluster`).

## Repository layout

| Path | Purpose |
|---|---|
| `bootstrap/root-app.yaml` | App-of-apps root Application (one-time bootstrap). |
| `apps/` | Child `Application` manifests — one per app. Watched recursively by root. |
| `manifests/<app>/` | The Kubernetes resources for each app (Kustomize). |
| `docs/` | How-to guides. |

## Bootstrap (one time, already done for this cluster)

```sh
# On the cluster (or with a kubeconfig pointed at it):
kubectl apply -f https://raw.githubusercontent.com/ikscream/argo.kiitconsulting.com/main/bootstrap/root-app.yaml
```

That single apply is the only imperative step. From then on Argo CD pulls this
repo (public — no credentials needed) and syncs. Verify:

```sh
kubectl -n argocd get applications
# NAME      SYNC STATUS   HEALTH STATUS
# root      Synced        Healthy
# podinfo   Synced        Healthy
```

## The example app — `podinfo`

[`apps/podinfo.yaml`](./apps/podinfo.yaml) deploys
[`manifests/podinfo/`](./manifests/podinfo) (a 2-replica
[podinfo](https://github.com/stefanprodan/podinfo) Deployment + Service +
Ingress) into the `demo` namespace. It proves the whole path end-to-end and is
published at **<https://podinfo.kiitconsulting.com>** behind a Let's Encrypt cert
(cert-manager HTTP-01 via the `letsencrypt-prod` ClusterIssuer + Traefik). Or
reach it in-cluster:

```sh
kubectl -n demo port-forward svc/podinfo 8080:80   # then http://localhost:8080
```

The public hostname needs a **DNS-only** A record pointing at the node — the
`Ingress` ([`manifests/podinfo/ingress.yaml`](./manifests/podinfo/ingress.yaml))
and the cert are otherwise fully declarative. This is the template for exposing
any app: add an `Ingress` with the `cert-manager.io/cluster-issuer` annotation +
a `tls` block, and create the DNS record.

## Adding your own application

See [`docs/adding-an-application.md`](./docs/adding-an-application.md). Short
version: drop manifests under `manifests/<name>/`, copy `apps/podinfo.yaml` to
`apps/<name>.yaml` and point its `path:` at them, then `git push`. Argo CD does
the rest.

## Sync policy & conventions

- **Automated sync** with `selfHeal: true` (reverts manual drift) and
  `prune: true` (deletes resources removed from git).
- **`CreateNamespace=true`** so each app owns its namespace without a separate
  manifest.
- **`finalizers: [resources-finalizer.argocd.argoproj.io]`** so deleting an
  Application cascades to its cluster resources.
- Keep one namespace per app; name the `Application`, its `path`, and the
  namespace consistently.

## Making this repo private later

It is public today, so Argo CD reads it anonymously. If you make it private, add
repo credentials to Argo CD (Settings → Repositories, or a `repo-…` Secret) — a
GitHub deploy key or PAT with read access. Nothing else changes.
