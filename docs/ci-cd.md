# CI/CD — build in GitHub, store in Hetzner S3, deploy with Argo CD

This is the end-to-end path from a `git push` of source code to a running,
TLS-terminated service — with **image blobs stored in Hetzner Object Storage**.

```
 GitHub Actions ──build (buildx)──▶ registry.kiitconsulting.com ──blobs──▶ Hetzner S3 (bucket kiit-registry)
      │                              (distribution registry:3, S3 driver, in-cluster)
      └── writes newTag ──▶ Forgejo: manifests/echo/kustomization.yaml ──▶ Argo CD sync ──▶ echo.kiitconsulting.com
```

- **Build** happens on GitHub's runners (no build load on the 4 GB node).
- **Store**: the image is pushed to the in-cluster registry, whose storage driver
  writes every blob into the Hetzner S3 bucket. Nothing is stored on the node's
  disk.
- **Deploy trigger** is pure GitOps: CI commits the new image tag back to this
  repo; Argo CD reconciles. CI never talks to the Argo CD API.
- **The build runs on the mirror and writes to the source of truth.** Workflows
  are triggered by GitHub (where the mirror push lands) but the tag write-back
  goes to **Forgejo** over `git.kiitconsulting.com`, authenticated with the
  `FORGEJO_TOKEN` Actions secret (`ci_writeback_token` in
  `op://ai-skills/forgejo-kiit`). Pushing the tag to GitHub instead would deploy
  nothing — Argo CD does not read it — and the next mirror sync would erase the
  commit. The same applies to `ikscream/prj-bayes-markets`, which writes the
  `bayes-ingest` tag here. See [`forgejo.md`](./forgejo.md).

## The registry (S3-backed)

- Manifests: [`manifests/registry/`](../manifests/registry) — `registry:3` with a
  config that points the `s3` storage driver at `kiit-registry` in `fsn1`.
  Published at **<https://registry.kiitconsulting.com>** (Traefik + Let's Encrypt).
- **Auth:** htpasswd basic auth. Push/pull user is `ci`; creds in 1Password at
  `op://ai-skills/registry-kiit`.
- **S3 credentials:** `op://ai-skills/hetzner/s3` (`s3_access_key`, `s3_secret_key`).

### Secrets are NOT in git (bootstrap once)

The registry's two Secrets and the kubelet pull Secret are created out-of-band
from 1Password (never committed). Recreate them like this:

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl create ns registry --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns echo     --dry-run=client -o yaml | kubectl apply -f -

# S3 keys for the storage driver (AWS_* env names)
kubectl -n registry create secret generic registry-s3 \
  --from-literal=AWS_ACCESS_KEY_ID="$(op read op://ai-skills/hetzner/s3/s3_access_key)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(op read op://ai-skills/hetzner/s3/s3_secret_key)"

# htpasswd auth (bcrypt) for user 'ci'
kubectl -n registry create secret generic registry-auth \
  --from-literal=htpasswd="$(htpasswd -nbB ci "$(op read op://ai-skills/registry-kiit/password)")"

# kubelet pull secret so the echo namespace can pull private images
kubectl -n echo create secret docker-registry registry-pull \
  --docker-server=registry.kiitconsulting.com \
  --docker-username=ci \
  --docker-password="$(op read op://ai-skills/registry-kiit/password)"
```

The `bayes` namespace (PostgreSQL + Redis + `ingest`) needs its own two:

```sh
kubectl create ns bayes --dry-run=client -o yaml | kubectl apply -f -

# the PostgreSQL superuser password the database and ingest both read
op read op://ai-skills/bayes-postgres/password | tr -d '\n' | \
  kubectl -n bayes create secret generic bayes-postgres \
    --from-file=password=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -

# pull secret, because ingest comes from the private registry
kubectl -n bayes create secret docker-registry registry-pull \
  --docker-server=registry.kiitconsulting.com \
  --docker-username=ci \
  --docker-password="$(op read op://ai-skills/registry-kiit/password)"
```

The `ai-portal` namespace needs the same pull secret plus three values of its own.

`WS_COOKIE_SECRET` signs the portal's WebSocket cookie/URL token. `/ws` is a Cloudflare
Access **bypass** path, so that token is what authenticates a browser's socket — and it is
the only path iOS has, since WebKit sends neither headers nor cookies on a `wss://`
handshake. It would otherwise be derived from `PORTAL_BASIC_AUTH`/`DISPATCH_TOKEN`, so
setting it explicitly is also what keeps every browser socket alive across a token rotation.

`DISPATCH_TOKEN` is the Bearer credential on `/dispatch`, the **only** thing standing
between that endpoint and anything that can reach the Service. Portal and dispatcher read
the same key, so they cannot drift.

`ai-portal-claude` holds the subscription auth: `CLAUDE_CODE_OAUTH_TOKEN` is the host
default account, and `CLAUDE_ACCOUNTS` is the JSON pool (`{name:{username,token}}`) a
project can pin one of by name. Only the **names** ever reach the portal or the browser.

`ai-portal-op` holds the 1Password service-account token the dispatcher brokers secrets
with. A project's `op://…` refs are resolved dispatcher-side (the agent sees values only);
a project with `opDirect: true` additionally gets the token in its own environment, which
is what makes the baked `op` CLI work in an agent's Bash. Omit it and `op://` refs resolve
to an empty string rather than erroring, so prefer a service account scoped to the vaults
this cluster actually needs.

`ai-portal-s3` holds the history-bucket IAM keys, and **both** Deployments mount it: the
dispatcher archives finished session transcripts and pulls uploaded files down, while the
portal mirrors its usage-stats/audit rings and performs the PUT half of file upload. Wire
only one and upload breaks at whichever step you skipped. The IAM user has no
`DeleteObject`; the bucket is versioned, so overwrites are recoverable.

Transcript archiving additionally needs dispatcher **≥ 2.1.2** (ai-portal-v2 PRs #3 + #4):
earlier builds only archived from the container agent path, so this cluster's
`AGENT_MODE=inprocess` wrote nothing even with the credentials correctly mounted.

```sh
kubectl create ns ai-portal --dry-run=client -o yaml | kubectl apply -f -

# Portal/dispatcher auth. Both keys are generated once and kept in 1Password;
# `--from-file=…=/dev/stdin` keeps the values out of argv on the node.
kubectl -n ai-portal create secret generic ai-portal-auth \
  --from-literal=WS_COOKIE_SECRET="$(op read op://ai-skills/ai-portal-v2/ws_cookie_secret)" \
  --from-literal=DISPATCH_TOKEN="$(op read op://ai-skills/ai-portal-v2/dispatch_token)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Claude subscription pool. Render the JSON where the tokens are read (a workstation with
# `op`), pipe the manifest to the node — never paste a token into a shell on the box.
kubectl -n ai-portal create secret generic ai-portal-claude \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN="$(op read op://ai-skills/claude-token/password)" \
  --from-literal=CLAUDE_ACCOUNTS="$(cat accounts.json)" \
  --dry-run=client -o yaml | kubectl apply -f -

# The secret broker. Piped over stdin rather than --from-literal so the token never
# appears in argv (or in the shell history of whoever runs this).
printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" | kubectl -n ai-portal create secret generic ai-portal-op \
  --from-file=OP_SERVICE_ACCOUNT_TOKEN=/dev/stdin

# S3 history/upload credentials, mounted by BOTH the portal and the dispatcher. The
# bucket and region are not secret and live in the manifests; only these two keys here.
kubectl -n ai-portal create secret generic ai-portal-s3 \
  --from-literal=AWS_ACCESS_KEY_ID="$(op read 'op://chaineye/aws/AI Portal History/s3_access_key')" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(op read 'op://chaineye/aws/AI Portal History/s3_secret_key')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n ai-portal create secret docker-registry registry-pull \
  --docker-server=registry.kiitconsulting.com \
  --docker-username=ci \
  --docker-password="$(op read op://ai-skills/registry-kiit/password)"
```

> Upgrade path: replace the out-of-band step with **Sealed Secrets** or
> **External Secrets** to bring secrets under GitOps safely.

## The build workflow

[`.github/workflows/echo.yml`](../.github/workflows/echo.yml):

1. Compute a short-SHA tag.
2. `docker login registry.kiitconsulting.com` with the `REGISTRY_USERNAME` /
   `REGISTRY_PASSWORD` repo secrets.
3. `docker/build-push-action` builds `examples/echo` and pushes
   `:$(sha)` + `:latest` (blobs land in S3).
4. `sed` the new tag into `manifests/echo/kustomization.yaml` and commit it back
   (`[skip ci]`). Argo CD deploys within a minute.

Repo secrets are already set (`gh secret list`): `REGISTRY_USERNAME=ci`,
`REGISTRY_PASSWORD=<op://ai-skills/registry-kiit>`.

## Wire your OWN GitHub project to push here

In any other repo you want to build:

1. Add these **repository secrets** (Settings → Secrets and variables → Actions),
   or org-level so every repo inherits them:
   - `REGISTRY_USERNAME` = `ci`
   - `REGISTRY_PASSWORD` = value of `op://ai-skills/registry-kiit/password`
2. Reuse the login + build-push steps, pushing to
   `registry.kiitconsulting.com/<your-app>:<tag>`:

   ```yaml
   - uses: docker/login-action@v3
     with:
       registry: registry.kiitconsulting.com
       username: ${{ secrets.REGISTRY_USERNAME }}
       password: ${{ secrets.REGISTRY_PASSWORD }}
   - uses: docker/build-push-action@v6
     with:
       context: .
       push: true
       tags: registry.kiitconsulting.com/<your-app>:${{ github.sha }}
   ```
3. To deploy it, add `manifests/<your-app>/` + `apps/<your-app>.yaml` in THIS
   repo (see [`adding-an-application.md`](./adding-an-application.md)), and have
   your CI write the tag back — or point Argo CD Image Updater at the repo.

## Manual push (debug)

```sh
docker login registry.kiitconsulting.com -u ci      # password from op://ai-skills/registry-kiit
docker build -t registry.kiitconsulting.com/echo:test examples/echo
docker push registry.kiitconsulting.com/echo:test
curl -s -u ci:<pw> https://registry.kiitconsulting.com/v2/_catalog
```
