# MEMORY.md

Durable, non-obvious project memory for agents — the *why* behind decisions and
constraints that you can't read off the code. Append new learnings; don't
duplicate `README.md`/`CLAUDE.md`; never store secrets.

## Decisions & rationale

- **Images live in Hetzner S3 on purpose.** The owner explicitly wanted image
  storage on Hetzner Object Storage, so we run an in-cluster `registry:3` with the
  S3 storage driver (bucket `kiit-registry`, `fsn1`) rather than using ghcr.io.
  S3 is not a registry — the registry is what makes "push image to S3" real.
- **Certs are DNS-01 now (was HTTP-01).** Originally the shared Cloudflare token
  was **IP-restricted** (rejected from the server: `9109 Cannot use the access
  token from location`) and DNS-edit-only, forcing HTTP-01 + grey-cloud records.
  On 2026-08-21 the owner widened the token (now usable from the server, with
  Zone:DNS:Edit, Zone:Read, SSL:Edit, Rulesets:Edit, Access:Apps:Edit), so the
  `letsencrypt-prod` ClusterIssuer was switched to **Cloudflare DNS-01**
  (`manifests/cert-manager`). DNS-01 needs no inbound HTTP, so hosts can now be
  **orange (proxied)** — required for Cloudflare Access SSO, which intercepts the
  HTTP-01 challenge path and would break it. The old "must stay grey" rule is
  **dead**; see [[cloudflare-access-sso]] / `docs/cloudflare-access-sso.md`.
- **Edge Access is not an origin gate, and arming one breaks `httpGet` probes.** Every
  host resolves to the same node IP, so a `Host:`-spoofed direct request skips Access —
  tolerable for `argo`/`grafana-k8s` (they have their own logins), not for `ap`, where
  the portal reads "no auth configured" as "allow everything". So `ap` verifies the
  `Cf-Access-Jwt-Assertion` at the origin (`PORTAL_ACCESS_*`). Two things only show up
  once you do: a WebSocket path needs its own **`bypass`** Access app (an upgrade cannot
  follow a 302 login), and the kubelet's probe — no assertion, no `CF-Connecting-IP` —
  gets a **measured 403**, i.e. liveness failing every period on a healthy pod. Probe
  from **inside** the container against `127.0.0.1`, which fail-closed origins exempt
  because such a call cannot come from off the box. Do **not** reach for an IP allowlist
  instead: it keys on the client-settable `CF-Connecting-IP`, trustworthy only when
  Cloudflare is the sole path in — and here it isn't.
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

## ai-portal dispatcher (added 2026-08-21)

- **Agents run inside the dispatcher pod, and that is a compromise, not the design.**
  v1 gives every prompt a hardened ephemeral sibling container through the host's
  docker socket. k3s runs containerd, there is no docker socket to mount, so v2
  runs `AGENT_MODE=inprocess`: an agent is a `query()` in the dispatcher process.
  Three consequences follow directly. The pod's memory limit is the agent's
  ceiling and an OOM kills the dispatcher and every live session with it (hence
  `MAX_AGENTS=2` against a 2Gi limit); the container's security context is the
  only sandbox an agent has; and agent `run_in_background` work dies at end of
  run. Agents as Kubernetes **Jobs** is the native answer and the next step.
- **One dispatcher replica, `Recreate`, for the same reason the portal has one.**
  The portal keeps `dispatchers` as a last-writer-wins Map keyed by host id. Two
  overlapping pods mean the new one registers and then the old one's closing
  socket deletes the live entry — the host reads `connected:false` while a
  healthy dispatcher keeps answering heartbeats. v1 hit exactly this on its
  tunnel-connected host; RollingUpdate would reproduce it on every deploy.
- **Nothing about the dispatcher is published.** It dials the portal's ClusterIP
  Service outbound, so it needs no Ingress, never meets Traefik, and never meets
  the Access gate. Its only credential is the Bearer `DISPATCH_TOKEN`, which both
  halves read from the same `ai-portal-auth` key so they cannot drift.
- **`$HOME` has to be moved onto the volume.** The image points it at
  `/home/node`, which is the ephemeral layer, and the engine writes its session
  transcripts there — so a rollout would discard exactly the sessions that
  `dispatcher-sessions.json` (on the volume) still refers to, and "continue"
  would resume into nothing.
- **Verified end-to-end 2026-08-21**: host `k3s` registered, a prompt ran through
  the browser's own `/ws` message shapes (tool approvals included), the follow-up
  prompt resumed the same session id from context, the write landed on the
  workspace volume, and spend attributed to the pinned account in the Usage view.
  The rate-limit prober populates live 5h/weekly bars for all three accounts.
- **The Console needs a real project.** The dispatcher falls back to a single
  project rooted at `BASE_DIRECTORY` (`/workspace`), which is also the
  confinement root. Repos have to be cloned onto that volume before they can be
  added in the Projects UI, which only accepts a directory that already exists.

## Forgejo, and moving the source of truth in-cluster (added 2026-08-24)

- **The repo that deploys the cluster is now hosted on the cluster.** Forgejo
  runs in `forgejo` and serves `ikscream/argo.kiitconsulting.com`; Argo CD
  reconciles from it and GitHub is a push mirror. This was a deliberate choice
  to stop depending on GitHub, taken knowing it buys a circular dependency:
  Forgejo is deployed by the repository Forgejo serves. Losing the pod or its
  PVC does not stop anything already running — Argo CD leaves live resources
  alone when a source is unreachable — but it does mean no change can be made
  through git until Forgejo is back. `docs/forgejo.md` has the break-glass.
- **Argo CD clones the ClusterIP, not `git.kiitconsulting.com`.** Every
  `repoURL` is `http://forgejo.forgejo.svc.cluster.local:3000/…`. Routing the
  control loop through the public host would have made reconciliation depend on
  DNS, Cloudflare, Traefik and a valid certificate — the very things you need
  GitOps working to repair. It also avoids hairpinning back through the node's
  own public IP. Plain HTTP is fine here; the hop never leaves the pod network.
- **Forgejo is grey-cloud and must stay that way.** It is the one app besides
  the registry that cannot sit behind Cloudflare Access: `git clone`/`push` over
  HTTPS cannot follow an SSO redirect, and CI pushes image tags through it. Its
  own login plus `REQUIRE_SIGNIN_VIEW` is the gate, which is sufficient here
  precisely because — unlike the ai-portal — Forgejo does not treat "no auth
  configured" as "allow everything".
- **SQLite, not PostgreSQL.** One user on a single node; a second database
  StatefulSet would cost more memory than the thing it manages, on a box that
  already OOM-starved once at 4 GB. The consequence is `replicas: 1` +
  `Recreate` forever: SQLite takes one writer and the PVC is RWO.
- **The cutover was staged, and the canary earned its keep.** Order was: deploy
  Forgejo from GitHub → seed and verify the history matched byte for byte →
  create the Argo CD credential and prove `argocd-repo-server` could
  `git ls-remote` the Service → flip **one** app (`podinfo`) and watch it go
  Synced/Healthy → only then flip the other nine and the root. Each step was
  reversible on its own.
- **`bootstrap/root-app.yaml` is not self-managed.** `root` watches `apps/`, and
  root-app.yaml lives in `bootstrap/`, so changing root's own `repoURL` in git
  does nothing — it has to be `kubectl apply`-ed on the node. That asymmetry is
  easy to miss and leaves root quietly still reading GitHub.
- **Forgejo is backed up nightly; bayes PostgreSQL still is not.**
  `manifests/forgejo/backup.yaml` dumps at 03:17 UTC and pushes an encrypted
  restic snapshot to `kiit-registry/backups/forgejo` (10.4 MB dump → 2.9 MB
  stored, 14 daily / 8 weekly / 12 monthly). Things that were not obvious while
  building it:
  - **The dump is a credential-bearing artefact.** It ships `app.ini`, i.e.
    `SECRET_KEY` and `INTERNAL_TOKEN`, which decrypt the GitHub PAT behind all
    19 push mirrors. That is why it is encrypted client-side and why the
    passphrase is in an out-of-band Secret rather than the Job spec.
  - **A file-level copy would be silently torn.** SQLite runs in WAL mode with a
    multi-MB `-wal`; only `forgejo dump` (or a WAL-aware copy) is consistent.
    And there is nothing underneath to fall back on — Hetzner Cloud Volumes have
    **no snapshot feature**, and Hetzner server backups image only the root disk.
  - **The Forgejo image has `tar`/`gzip` but no `sqlite3` and no `restic`**, so
    dump and upload are two containers, not one.
  - **Dump `--type tar`, not `tar.gz`:** restic cannot dedupe or compress
    through a gzip stream. Dedup between consecutive dumps is poor anyway
    (~0.5 MB of 10 MB) because most of the archive is already-compressed git
    packs and a changing SQLite file.
  - **The AWS history bucket could not have hosted this**: its IAM policy is
    Get+Put with **no Delete**, so `restic forget --prune` cannot work there.
    Hetzner S3 can prune — at the cost of being the same provider and DC (fsn1)
    as the volume it protects.
