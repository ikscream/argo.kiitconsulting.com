# MEMORY.md

Durable, non-obvious project memory for agents — the *why* behind decisions and
constraints that you can't read off the code. Append new learnings; don't
duplicate `README.md`/`CLAUDE.md`; never store secrets.

## Decisions & rationale

- **Images live in Hetzner S3 on purpose.** The owner explicitly wanted image
  storage on Hetzner Object Storage, so we run an in-cluster `registry:3` with the
  S3 storage driver (bucket `kiit-registry`, `fsn1`) rather than using ghcr.io.
  S3 is not a registry — the registry is what makes "push image to S3" real.
- **HTTP-01, not DNS-01, for certs.** The shared Cloudflare token is
  **IP-restricted** (works from the operator's box, rejected from the server:
  `9109 Cannot use the access token from location`) and **DNS-edit + zone-read
  only** (no zone-settings/rulesets scope). So cert-manager can't do DNS-01 from
  the cluster and per-hostname Cloudflare SSL modes can't be set via API. HTTP-01
  needs only port 80 + a DNS-only A record — hence every app hostname must stay
  **grey-cloud**. Flipping one to proxied silently breaks its cert renewal.
- **Builds run off the node.** The host is a single `cx23` (2 vCPU / 4 GB). Image
  builds are done on GitHub's runners, not in-cluster, to avoid OOM/noisy-neighbor
  on the box that also serves the apps. Revisit only if you outgrow Actions.
- **Secrets are out-of-band, not GitOps-managed (yet).** Chosen for lightness:
  `registry-s3`/`registry-auth`/`registry-pull` are created imperatively from
  1Password. Trade-off accepted; Sealed Secrets / External Secrets is the
  documented upgrade path. Pods won't start until these Secrets exist, so a
  fresh-cluster rebuild must recreate them before/around the Argo sync.
- **Don't use Kaniko** if you add in-cluster builds later — Google archived it;
  use BuildKit/buildx or Buildah.

## Constraints & gotchas (non-code)

- **Single-node, non-HA cluster.** The registry runs one replica; it logs a
  "random HTTP secret" warning on start — harmless at one replica, but set
  `REGISTRY_HTTP_SECRET` before scaling out or blob uploads can fail behind an LB.
- **True client IP is lost** at the k3s ServiceLB/Traefik SNAT hop; `echo` shows
  `10.42.0.x`. Not a bug in the app — an infra choice. Fix with Traefik
  `externalTrafficPolicy: Local` only if you actually need visitor IPs.
- **`podinfo` → namespace `demo`** is a historical naming accident from the first
  example; every later app uses its own name. Don't propagate it.
- **The node IP `178.104.210.183` was reused** when the host was re-provisioned
  (Hetzner happened to reassign the same address); don't assume that on the next
  rebuild — update DNS records if it changes.
- **Argo CD default reconcile is ~3 min.** For demos/tests, force it with a
  `argocd.argoproj.io/refresh=hard` annotation instead of waiting.

## Monitoring

- **`grafana.kiitconsulting.com` is taken** — it's a Cloudflare Tunnel CNAME to a
  *different* Grafana (left untouched). The in-cluster Grafana uses
  **`grafana-k8s.kiitconsulting.com`**.
- kube-prometheus-stack is **heavy for this 4 GB node** — deployed trimmed
  (Alertmanager off, Prometheus 12h retention + ≤900Mi, control-plane monitors
  off). If the node OOMs, cut Prometheus retention/limits before anything else.
- Argo CD deploys it as a **Helm-source Application with `ServerSideApply=true`**
  (the kube-prometheus-stack CRDs are too large for client-side apply).
- Grafana↔Prometheus is auto-wired by the chart sidecar (datasource `Prometheus`);
  dashboards are gnetId imports — bump `revision` from
  `https://grafana.com/api/dashboards/<id>` when updating.

## Status / verification

- Verified end-to-end on **2026-08-21**: CI built `echo`, pushed to the registry
  (blobs confirmed in the S3 bucket), tag written back, Argo CD deployed it, and
  `https://echo.kiitconsulting.com` served JSON over a valid Let's Encrypt cert.
  `root`, `echo`, `podinfo`, `registry` were all `Synced/Healthy`.

## Unverified / flagged

- The **echo Go binary has not been run through `go test`** (there are no tests
  yet) and wasn't compiled locally during authoring — it is built only by CI.
  Add unit tests if the app grows beyond a demo.
- **Cluster-rebuild reproducibility is partial:** manifests + provisioning scripts
  are in git, but the out-of-band Secret bootstrap and DNS records are manual
  steps — a from-scratch rebuild is documented, not automated/tested.
