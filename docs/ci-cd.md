# CI/CD — build in GitHub, store in Hetzner S3, deploy with Argo CD

This is the end-to-end path from a `git push` of source code to a running,
TLS-terminated service — with **image blobs stored in Hetzner Object Storage**.

```
 GitHub Actions ──build (buildx)──▶ registry.kiitconsulting.com ──blobs──▶ Hetzner S3 (bucket kiit-registry)
      │                              (distribution registry:3, S3 driver, in-cluster)
      └── writes newTag ──▶ manifests/echo/kustomization.yaml ──▶ Argo CD sync ──▶ echo.kiitconsulting.com
```

- **Build** happens on GitHub's runners (no build load on the 4 GB node).
- **Store**: the image is pushed to the in-cluster registry, whose storage driver
  writes every blob into the Hetzner S3 bucket. Nothing is stored on the node's
  disk.
- **Deploy trigger** is pure GitOps: CI commits the new image tag back to this
  repo; Argo CD reconciles. CI never talks to the Argo CD API.

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
