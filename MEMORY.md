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
- **The node was resized `cx23` (4 GB) → `cx33` (8 GB)** on 2026-08-21 because the
  full stack (+ bayes) OOM-starved 4 GB (Grafana `/api/health` timing out →
  Traefik "no available server"). Resize = poweroff → Hetzner `change_type`
  (`upgrade_disk=false`, disk stays 40 GB, reversible) → poweron; there is **no
  `ai-hetzner` resize command**, use the API action directly. kube-prometheus-stack
  is still trimmed (Alertmanager off, Prometheus 12h + ≤900Mi, control-plane
  monitors off).
- **Grafana is pinned to `12.4.9`**, NOT the chart's default 13.2.x. Grafana 13.2
  crash-loops here on its new unified-storage / "secure values" subsystem
  (`cleaning up inactive secure values: context deadline exceeded`, ~18s requests
  → liveness kills it). Also relaxed the readiness probe (default `timeoutSeconds:
  1` flaps). If you bump the chart, re-check the Grafana image tag.
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

## bayes.markets (added 2026-08-21)

- **Its source is in another repo, and CI pushes here.** `manifests/bayes-markets`
  is deployed from this repo, but the `ingest` image is built by
  `ikscream/prj-bayes-markets` (`.github/workflows/ingest.yml`), which checks this
  repo out with a `GITOPS_TOKEN` PAT and commits the new `newTag`. The default
  `GITHUB_TOKEN` cannot do that - it is scoped to the repo it runs in. If tag
  write-back starts failing with 403, that PAT expired.
- **One Application for three workloads** (`postgres`, `redis`, `ingest`) in
  namespace `bayes`, against the usual one-app-per-namespace habit: `ingest` is
  meaningless without the two stores, so three Argo tiles would only ever go green
  or red together.
- **`ingest` collects, as of 2026-08-21, and it is a StatefulSet for one reason:
  one upstream socket.** It holds one Hyperliquid websocket, writes every BTC fill
  into hourly partitions of `hl_trade`, and publishes a tick a second to Redis. A
  Deployment rolls by starting the new pod before stopping the old one, so every
  rollout would briefly run two sockets and two writers; a one-replica StatefulSet
  terminates first. On top of that it holds `lease/ingest-writer` and opens the
  socket only while it holds it, because `replicas: 1` does not survive a
  `kubectl scale`, a hand-run copy of the image, or two revisions racing.
- **Do not `kubectl scale ingest --replicas=2` expecting throughput.** The second
  pod becomes a follower: no socket, no writes. That is correct, and it is not
  useful. It is also the only sanctioned way to test the lease handover.
- **The upstream is Hyperliquid, not Polymarket**, though the design drawing says
  Polymarket. The site settles its rounds on the Hyperliquid BTC 5m candle, so
  that tape is the one worth keeping first. The Polymarket firehose is a second
  source with a second schema and is not wired up.
- **Its RBAC is one named Lease and nothing else** (`Role/ingest-lease`:
  `create` on leases, `get`/`update` on `ingest-writer`). If the status page shows
  `lease.error` as a 403, that Role or its binding is what to look at - the pod
  will keep answering happily while collecting nothing.
- **The public Ingress was kept, not deleted as previously planned.** It is now the
  only outside view of whether the cluster is collecting anything (`rows_written`,
  `lease.leader`, `upstream.state`), which is worth more than the small surface it
  exposes. It serves no data, only counters.
- **Retention is `RETENTION_HOURS` on the StatefulSet, default 72, and it deletes
  history.** The tiering CronJob and its S3 bucket do not exist, so nothing is
  archived before a partition is dropped. 108 bytes a row on disk, so ~70 MB/day
  and ~210 MB for the window, against a 5Gi volume.
- **PostgreSQL is a plain StatefulSet, not CloudNativePG.** The project's design
  calls for the operator; an operator on a 2 vCPU / 4 GB node costs more than the
  one database it manages. Revisit when backups or failover are actually needed.
  Storage is `local-path` (a directory on the node), so there is no backup yet -
  and it is no longer an empty database, it is the only copy of the tape.
- **`selfHeal` reverts a `kubectl scale` in about one second**, which matters when
  testing the lease: scaling `ingest` to 0 to force a handover does not give you a
  window, because Argo recreates the pod immediately and it wins the race for the
  expired lease. To make a window, patch the Application's `syncPolicy.automated`
  to `null` first, then restore it (`{"prune":true,"selfHeal":true}`). Verified on
  2026-08-21 this way: a second process ran as a follower with no socket and no
  writes, took the lease 12s after the holder stopped, and gave it back when
  stopped itself - zero primary-key conflicts across three handovers.
