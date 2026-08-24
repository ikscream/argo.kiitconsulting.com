# Forgejo — the GitOps source of truth

[Forgejo](https://forgejo.org) runs in-cluster at
**<https://git.kiitconsulting.com>** (namespace `forgejo`) and hosts
`ikscream/argo.kiitconsulting.com`, the repository Argo CD reconciles this
cluster from. GitHub is now a **mirror**, not the source.

## Shape

| | |
|---|---|
| Image | `codeberg.org/forgejo/forgejo:16.0.3-rootless` (runs as uid 1000) |
| Database | SQLite on the PVC — one user, one node; a second PostgreSQL would cost more than it manages |
| Storage | `forgejo-data`, 10Gi, `local-path` (a directory on the node) |
| Replicas | 1, `strategy: Recreate` — RWO volume, and SQLite takes exactly one writer |
| Config | `FORGEJO__<section>__<KEY>` env vars, rendered into `app.ini` on the PVC at every start |
| Public | Ingress on `git.kiitconsulting.com`, **DNS-only (grey)**, Let's Encrypt via DNS-01 |
| Argo CD | clones `http://forgejo.forgejo.svc.cluster.local:3000/…` — **not** the public host |
| SSH | disabled |

### Why grey-cloud and not behind Cloudflare Access

`git clone` and `git push` over HTTPS cannot follow an SSO redirect, and CI
pushes image tags back through this host. Access would break both. Forgejo has
its own login, and `REQUIRE_SIGNIN_VIEW=true` plus `DISABLE_REGISTRATION=true`
keep the repositories private to the one account — unlike the ai-portal, this is
an app that survives being reachable directly (see the Access notes in
`docs/cloudflare-access-sso.md`).

### Why Argo CD uses the in-cluster Service, not `git.kiitconsulting.com`

Reconciling the cluster must not depend on DNS, Cloudflare, Traefik or a valid
certificate. Cloning through the ClusterIP keeps the control loop inside the pod
network, and sidesteps hairpin NAT back through the node's public IP. Traffic is
plain HTTP over the cluster network by design.

### Why no SSH

Port 22 on the node belongs to the host's own `sshd`, so Forgejo's built-in
server would need a NodePort and a firewall change. Clone over HTTPS with a
token instead.

## Credentials

| What | Where |
|---|---|
| Admin account (`ikscream`) | `op://ai-skills/forgejo-kiit` |
| Argo CD read token | Forgejo → Settings → Applications, token `argocd` (`read:repository`); lives only in the `repo-forgejo-gitops` Secret |
| CI write-back token | token `ci-writeback` (`write:repository`); GitHub Actions secret `FORGEJO_TOKEN` |

Admin CLI (user creation, password reset, `doctor`):

```sh
kubectl -n forgejo exec -it deploy/forgejo -- forgejo admin user list
```

## The Argo CD repository Secret (out-of-band, never in git)

```sh
kubectl -n argocd create secret generic repo-forgejo-gitops \
  --from-literal=type=git \
  --from-literal=url=http://forgejo.forgejo.svc.cluster.local:3000/ikscream/argo.kiitconsulting.com.git \
  --from-literal=username=ikscream \
  --from-literal=password="$(op read 'op://ai-skills/forgejo-kiit/argocd_token')"
kubectl -n argocd label secret repo-forgejo-gitops \
  argocd.argoproj.io/secret-type=repository --overwrite
```

## The circular dependency — read this before you need it

**Forgejo is deployed by the repository Forgejo serves.** If the pod is down or
the PVC is lost, Argo CD cannot sync *anything*, including Forgejo itself.
Nothing already running stops — Argo CD leaves live resources alone when it
cannot reach a source — but you have no way to change the cluster through git
until Forgejo is back.

This is the accepted cost of self-hosting the source of truth. Two things make
it recoverable:

1. **GitHub is a push mirror.** Every push to Forgejo is mirrored to
   `github.com/ikscream/argo.kiitconsulting.com`, so a complete copy always
   exists off-box.
2. **Break-glass: point Argo CD back at GitHub.** On the node:

   ```sh
   export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
   OLD=http://forgejo.forgejo.svc.cluster.local:3000/ikscream/argo.kiitconsulting.com.git
   NEW=https://github.com/ikscream/argo.kiitconsulting.com.git

   # root first — it owns every other Application
   kubectl -n argocd patch application root --type merge \
     -p "{\"spec\":{\"source\":{\"repoURL\":\"$NEW\"}}}"
   for a in $(kubectl -n argocd get applications -o name); do
     kubectl -n argocd patch "$a" --type merge \
       -p "{\"spec\":{\"source\":{\"repoURL\":\"$NEW\"}}}"
   done
   ```

   Then fix Forgejo (restore the PVC, or redeploy `manifests/forgejo` by hand
   with `kubectl apply -k`), push the repo back into it, and flip the URLs
   forward again in git.

   Note the patches are drift Argo CD will self-heal away as soon as `root`
   syncs from GitHub — which is exactly what you want, because the GitHub copy
   still has the Forgejo URLs in it. During break-glass, land the URL flip in
   the GitHub copy too, or the loop will fight you.

## Backups

There are none yet. The PVC is `local-path`, i.e. a directory on the single
node, and the same is true of `bayes` PostgreSQL. The GitHub push mirror covers
git history; it does **not** cover users, tokens, issues or pull requests. If
this instance grows anything worth keeping beyond the commits, a `forgejo dump`
CronJob to the Hetzner bucket is the next step.
