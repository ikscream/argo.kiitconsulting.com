# CLAUDE.md

Operating manual for agents working in this repo. **These conventions override
default behavior — follow them exactly.** Human overview is in `README.md`;
durable non-obvious context is in `MEMORY.md`.

## What this is

The **GitOps source of truth** for the Argo CD instance at
`argo.kiitconsulting.com` (single-node k3s on the Hetzner `k3s-argocd` host). This
repo holds declarative workloads only; the cluster/host is provisioned in
[`ikscream/ai-hetzner`](https://github.com/ikscream/ai-hetzner) under
`provisioning/`. **Argo CD reconciles `main` continuously — merging to `main` is
deploying.** There is no separate deploy step.

## Architecture

- **App-of-apps.** `bootstrap/root-app.yaml` is one Argo CD `Application` watching
  `apps/` recursively. Each `apps/<name>.yaml` is an `Application` pointing at
  `manifests/<name>/` (Kustomize). All target `https://kubernetes.default.svc`
  (in-cluster).
- **Ingress/TLS.** Traefik (k3s default) + cert-manager `letsencrypt-prod`
  ClusterIssuer, **HTTP-01** challenge. Every public app = `Ingress` with
  `cert-manager.io/cluster-issuer: letsencrypt-prod`,
  `traefik.ingress.kubernetes.io/router.entrypoints: websecure`, and a `tls:`
  block. Each host needs a **DNS-only** Cloudflare A record at the node IP.
- **CI→registry→CD.** GitHub Actions builds `examples/echo`, pushes to the
  in-cluster `registry:3` (`registry.kiitconsulting.com`) whose S3 driver stores
  blobs in the Hetzner bucket `kiit-registry`, then writes the image tag into
  `manifests/echo/kustomization.yaml` and commits it back → Argo CD deploys.
  Details: `docs/ci-cd.md`.

## Build / test / run

- No cluster is created from here. The API server (6443) is firewalled; run
  `kubectl` **on the host** over SSH (`root@178.104.210.183`, key
  `op://ai-skills/ssh-k3s-argocd`) with `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.
- **Validate manifests before pushing:** `kubectl kustomize manifests/<app>`.
- **echo app** (`examples/echo`, Go stdlib): `go vet ./... && go build ./...`;
  `go run .` then `curl localhost:8080`; `docker build -t echo:dev .`.
- **Check deploys:** `kubectl -n argocd get applications` (expect `root`, `echo`,
  `podinfo`, `registry` all `Synced/Healthy`). Force a sync with
  `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`.

## Commits, branches & PRs

- **Use `ai-git`, never bare `git`/`gh`.** It injects 1Password-backed credentials
  and **signs commits**. Verify with `ai-git verify` (→ "Good git signature").
- **Branch per task; PR into `main`.** Do not commit product changes straight to
  `main` by hand (CI's tag write-back is the only automated exception).
- **[Conventional Commits](https://www.conventionalcommits.org/):**
  `type(scope): summary` (`feat`, `fix`, `docs`, `chore`, `ci`, `refactor`).
- **No AI attribution** in commit messages or PR bodies.
- Open PRs with `ai-git pr create`; watch CI with `ai-git pr status`.

## Secrets — never commit them

- **Kubernetes Secrets are created out-of-band from 1Password, never in git:**
  `registry-s3` + `registry-auth` (ns `registry`), `registry-pull` (ns `echo`),
  `bayes-postgres` + `registry-pull` (ns `bayes`, from `op://ai-skills/bayes-postgres`).
  Bootstrap commands live in `docs/ci-cd.md`. Kustomize/Argo manage only the
  non-secret manifests; the app pods depend on these Secrets already existing.
- **References:** S3 keys `op://ai-skills/hetzner/s3` (`s3_access_key`,
  `s3_secret_key`); registry push/pull `op://ai-skills/registry-kiit`; Cloudflare
  DNS token `op://ai-skills/cloudflare-api/api_token`; Argo CD admin
  `op://ai-skills/argocd-kiit`.
- Read secrets at runtime (`op read …`); never echo, log, or commit a value.
  GitHub Actions secrets (`REGISTRY_USERNAME/PASSWORD`) are set with `gh secret`.
- Secret management upgrade path (not yet done): Sealed Secrets / External Secrets.

## Conventions

- **One namespace per app**, name it after the app. Existing exception:
  `podinfo` → `demo` (don't replicate the mismatch in new apps).
- New public app = `manifests/<name>/{deployment,service,ingress,kustomization}.yaml`
  + `apps/<name>.yaml` + a DNS-only A record. Copy `echo` as the template.
- Keep app **source** out of this config repo where practical; `examples/echo` is
  a self-contained demo exception.
- Keep `README.md`, `CLAUDE.md`, and `MEMORY.md` consistent with the manifests.

## Gotchas

- **DNS records must stay DNS-only (grey cloud).** HTTP-01 renewals hit the origin
  on port 80; proxying (orange) breaks them, and the Cloudflare token is
  IP-restricted + DNS-edit-only, so DNS-01 can't run from the box as a fallback.
- **Don't hand-edit `manifests/echo/kustomization.yaml` `newTag`** — CI owns it.
  The write-back commit is unsigned (github-actions bot), uses `[skip ci]`, and
  the workflow's `paths:` filter prevents a build loop.
- **After a CI build, `origin/main` is ahead** of your local by the write-back
  commit — fetch/rebase before branching.
- **Real client IP is not preserved** — Traefik/k3s ServiceLB SNAT means `echo`
  reports the internal hop (`10.42.0.x`). Set the Traefik service
  `externalTrafficPolicy: Local` (or PROXY protocol) if you need true client IPs.
- **Registry auth returns 401 on `/v2/`**, so its probes are `tcpSocket`, not
  HTTP. Push/pull needs the `ci` basic-auth creds.
