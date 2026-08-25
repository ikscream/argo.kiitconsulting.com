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
| Storage | `forgejo-data`, 68Gi, `hcloud-volume` — a dedicated 70 GB Hetzner volume, not the node's root disk |
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
| CI write-back token | token `ci-writeback` (`write:repository`); Actions secret `GITOPS_TOKEN` in every repo whose CI writes here |

Admin CLI (user creation, password reset, `doctor`):

```sh
kubectl -n forgejo exec -it deploy/forgejo -- forgejo admin user list
```

## Telegram notifications

Every event in every repository is pushed to Telegram by a **system webhook**
(`/admin/hooks` → *System webhooks*, id 3): type `telegram`, "Send me
everything", branch filter `*`, delivering to **@kiitconsulting_bot** in the
owner's chat `194219638`. Bot token:
`op://ai-skills/wq2n2roohzy3aqod22tecundri` — the item is named
"Telegram Bot: @kiitconsulting_bot".

**A system webhook is the only kind that covers repositories that already
exist.** Forgejo has three flavours and the difference is easy to miss:

| Flavour | Fires for |
|---|---|
| **System** (`/admin/system-hooks/…`) | every repository, existing and future — one object |
| Default (`/admin/default-hooks/…`) | **copied into repositories created after it**; existing ones get nothing |
| Repository (repo → Settings → Webhooks) | that one repository |

**The trap: `POST /api/v1/admin/hooks` creates a *default* webhook**, even
though the sibling `GET` is documented as "List global (system) webhooks" — so
the hook silently covers no existing repository, and the `GET` does not list
what the `POST` just created. It also leaves the webhook's `meta` column empty,
which makes the admin UI log
`telegramHandler.Metadata(N): readObjectStart: expect { or n`. Create this hook
**through the admin UI form** (`/admin/system-hooks/telegram/new`, fields
`bot_token` + `chat_id`), not through the API.

This webhook is **Forgejo database state, not GitOps state** — it lives in the
`webhook` table, so it is covered by the nightly backup below and comes back
with a restore, but nothing in this repo recreates it.

## Actions — the runner on this node

Enabled since **2026-08-25**. `manifests/forgejo/runner.yaml` runs
**forgejo-runner 9.1.1** beside the forge, so the repositories this cluster
deploys from also build here. Workflows live in `.forgejo/workflows/`; see
[`ci-cd.md`](./ci-cd.md) for the pipeline and the per-repo secrets.

| | |
|---|---|
| Runner | `k3s-runner`, `capacity: 1` — one job at a time on a 4 vCPU node that also runs everything else |
| Labels | `ubuntu-latest` / `ubuntu-22.04` / `docker` → `catthehacker/ubuntu:act-22.04` |
| Docker | a **privileged** `docker:29-dind` sidecar; its socket is bind-mounted into each job container (`docker_host: automount`) so `docker/build-push-action` works |
| Disk | `/mnt/forgejo-data/runner` on the Hetzner volume — **not** the 38 GB root disk; a `prune` sidecar drops anything untouched for 72 h, nightly |
| Instance URL | the in-cluster Service, like Argo CD's — CI does not need DNS, Cloudflare or a valid cert to reach a forge three metres away |
| `uses:` resolution | `DEFAULT_ACTIONS_URL=https://github.com`, because the workflows use `docker/*` and `cloudflare/*`, which `code.forgejo.org` does not carry |

**The privileged daemon is a real grant.** Any job that reaches it can start a
container with any mount on this node. That is acceptable *only* because this
forge is single-user with registration disabled and every workflow in it is
written by that user. Rootless dind is the upgrade path if that ever changes.

### Registration is a shared secret, not a one-shot token

Both sides derive the runner's identity from the same 40-character hex secret
(`op://ai-skills/forgejo-runner`), so a rebuilt pod or a restored volume
re-registers itself instead of needing a fresh token from the admin UI. The pod
side is the `create-runner-file` initContainer; the server side is run once, by
hand:

```sh
# k8s Secret the Deployment reads (RUNNER_SECRET)
op read op://ai-skills/forgejo-runner/runner_secret | tr -d '\n' | \
  kubectl -n forgejo create secret generic forgejo-runner \
    --from-file=RUNNER_SECRET=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

# server side — idempotent, safe to re-run
op read op://ai-skills/forgejo-runner/runner_secret | tr -d '\n' | \
  kubectl -n forgejo exec -i deploy/forgejo -- sh -ec \
    'cat > /tmp/rs; forgejo forgejo-cli actions register --secret-file /tmp/rs \
       --name k3s-runner --labels ubuntu-latest,ubuntu-22.04,docker; rm -f /tmp/rs'
```

**The secret must be exactly 40 characters** — `op read` adds a newline, so the
`tr -d '\n'` is load-bearing; without it the command fails with "not 41".

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

## Storage — the dedicated volume

The repositories do **not** live on the node's root disk. That disk is 38 GB and
already ~67% full of container images, so on 2026-08-24 Forgejo was moved to its
own **70 GB Hetzner Cloud Volume** (`forgejo-data`, id `106694773`).

| | |
|---|---|
| Device | `/dev/disk/by-id/scsi-0HC_Volume_106694773` |
| Filesystem | ext4, UUID `980113bf-1050-4270-91ef-089610d7f874`, `tune2fs -m 0` |
| Mount | `/mnt/forgejo-data` via `/etc/fstab` |
| PV path | `/mnt/forgejo-data/gitea` (subdir, so `lost+found` stays out of `/var/lib/gitea`) |
| Class | `hcloud-volume` — `no-provisioner`, `WaitForFirstConsumer`, `Retain` |

**Two pieces of this are host state, not GitOps state**: the volume attachment
and the fstab line. `manifests/forgejo/pv.yaml` assumes both. If the node is
rebuilt, attach the volume and restore the mount *before* Argo CD syncs, or the
pod sits `Pending` on an unsatisfiable `nodeAffinity`. Growing it is a Hetzner
resize plus `resize2fs /dev/sdb`; the PV's `capacity` is only advisory for a
`local` volume, so bump it in git afterwards to keep the dashboards honest.

Adding a disk did not change the root disk's own problem — `/var/lib/rancher` is
19 GB of containerd on a 38 GB disk. Prune images (`k3s crictl rmi --prune`) or
give k3s a volume of its own; see MEMORY.md.

## Backups

`manifests/forgejo/backup.yaml` — a **nightly `forgejo dump` at 03:17 UTC**,
encrypted client-side by restic into the Hetzner bucket.

| | |
|---|---|
| Repository | `s3:https://fsn1.your-objectstorage.com/kiit-registry/backups/forgejo` |
| Contents | `forgejo-db.sql` (128 tables), `app.ini`, `forgejo.db` + WAL, all bare repos |
| Retention | `--keep-daily 14 --keep-weekly 8 --keep-monthly 12`, pruned every run |
| Size | 10.4 MB dump → **~2.9 MB** stored per snapshot |
| Secret | `forgejo-backup` (ns `forgejo`), out-of-band — see below |
| Verified | `restic check` runs at the end of every job and fails it on corruption |

The Job dumps in an initContainer (the Forgejo image) and uploads in the main
container (the restic image); a second pod mounting the RWO claim on the same
node is fine, and SQLite's WAL admits a concurrent reader, so **no downtime**.

**Why a dump rather than a volume snapshot:** the database is SQLite in WAL
mode, so a file-level copy taken while the pod runs is torn. Hetzner Cloud
Volumes have no snapshot feature at all, and Hetzner server backups image only
the root disk — an attached volume is never in them.

**Why it is encrypted:** the dump contains `app.ini`, and `app.ini` contains
`SECRET_KEY` and `INTERNAL_TOKEN` — the key that decrypts every secret in the
database, including the GitHub PAT behind all 19 push mirrors. A plaintext dump
in object storage is a credential leak with extra steps.

**What it does not cover:** the bucket is the same provider and the same
datacentre (`fsn1`) as the volume. It survives loss of the node, the volume, the
cluster, and human error — not loss of Hetzner fsn1. The GitHub push mirror
stays the out-of-provider copy of the commits. `bayes` PostgreSQL still has
nothing.

### The backup Secret (out-of-band, never in git)

```sh
kubectl -n forgejo create secret generic forgejo-backup \
  --from-literal=RESTIC_PASSWORD="$(op read 'op://ai-skills/forgejo-backup/restic_password')" \
  --from-literal=AWS_ACCESS_KEY_ID="$(op read 'op://ai-skills/hetzner/s3/s3_access_key')" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(op read 'op://ai-skills/hetzner/s3/s3_secret_key')"
```

**Losing `op://ai-skills/forgejo-backup/restic_password` makes every snapshot
unrecoverable noise.** It is deliberately not in this repo and not in the Job
spec — a Job spec is readable by anything that can `get jobs`.

### Restoring

Run the backup out of schedule, or see what is there:

```sh
kubectl -n forgejo create job --from=cronjob/forgejo-backup backup-now
kubectl -n forgejo logs job/backup-now -c upload -f
```

To pull an archive back, run restic against the same repository — from anywhere
with the passphrase and the S3 keys, including off this cluster:

```sh
export RESTIC_REPOSITORY=s3:https://fsn1.your-objectstorage.com/kiit-registry/backups/forgejo
export RESTIC_PASSWORD=$(op read 'op://ai-skills/forgejo-backup/restic_password')
export AWS_ACCESS_KEY_ID=$(op read 'op://ai-skills/hetzner/s3/s3_access_key')
export AWS_SECRET_ACCESS_KEY=$(op read 'op://ai-skills/hetzner/s3/s3_secret_key')

restic snapshots --tag forgejo
restic restore latest --target ./restore     # → ./restore/backup/forgejo-dump.tar
```

Then rebuild the instance from the archive — Forgejo has no `restore` command,
so this is a file operation ([upstream
guide](https://forgejo.org/docs/latest/admin/backup-and-restore/)):

1. Scale the Deployment to zero, but **suspend the Argo CD app first** or
   `selfHeal` scales it back in about a second:
   `kubectl -n argocd patch application forgejo --type merge -p
   '{"spec":{"syncPolicy":{"automated":null}}}'`.
2. Unpack the tar into an empty `/mnt/forgejo-data/gitea` on the node: `repos/`
   → `git/repositories/`, `data/` → the work dir, `app.ini` →
   `custom/conf/app.ini`. Keep `SECRET_KEY` and `INTERNAL_TOKEN` from the
   restored `app.ini`, or every stored token and mirror credential stays
   encrypted under a key you no longer have. `chown -R 1000:1000`.
3. Load `forgejo-db.sql` into a fresh `data/forgejo.db` with `sqlite3` — the
   restored `forgejo.db` + WAL is there as a second option, but the SQL dump is
   the consistent one. Neither `sqlite3` nor `restic` is in the Forgejo image;
   use a throwaway pod for both.
4. Scale back up, restore the sync policy, then `forgejo doctor check`.
