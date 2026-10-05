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

**This repo is hosted on the cluster it deploys.** The canonical remote is
Forgejo at `https://git.kiitconsulting.com/ikscream/argo.kiitconsulting.com`
(`docs/forgejo.md`); `github.com/ikscream/argo.kiitconsulting.com` is a **push
mirror**, kept as the off-box copy. **Push to Forgejo** — anything pushed to
GitHub directly is overwritten by the next mirror sync.

## Architecture

- **App-of-apps.** `bootstrap/root-app.yaml` is one Argo CD `Application` watching
  `apps/` recursively. Each `apps/<name>.yaml` is an `Application` pointing at
  `manifests/<name>/` (Kustomize). All target `https://kubernetes.default.svc`
  (in-cluster). Every `repoURL` is the **in-cluster Forgejo Service**
  (`http://forgejo.forgejo.svc.cluster.local:3000/…`), so the control loop does
  not depend on DNS, Cloudflare, Traefik or a valid cert.
- **Ingress/TLS.** Traefik (k3s default) + cert-manager `letsencrypt-prod`
  ClusterIssuer, **Cloudflare DNS-01** challenge (see Gotchas). Every public app
  = `Ingress` with `cert-manager.io/cluster-issuer: letsencrypt-prod`,
  `traefik.ingress.kubernetes.io/router.entrypoints: websecure`, and a `tls:`
  block. Each host needs a Cloudflare A record at the node IP — grey or orange.
- **CI→registry→CD.** **Forgejo Actions** — the runner in
  `manifests/forgejo/runner.yaml`, on this node — builds `examples/echo` from
  `.forgejo/workflows/`, pushes to the in-cluster `registry:3`
  (`registry.kiitconsulting.com`) whose S3 driver stores blobs in the Hetzner
  bucket `kiit-registry`, then writes the image tag into
  `manifests/echo/kustomization.yaml` and commits it back → Argo CD deploys.
  GitHub's runners were the build host until 2026-08-25. Details:
  `docs/ci-cd.md`.

## Build / test / run

- No cluster is created from here. The API server (6443) is firewalled; run
  `kubectl` **on the host** over SSH (`root@178.104.210.183`, key
  `op://ai-skills/ssh-k3s-argocd`) with `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`.
- **Validate manifests before pushing:** `kubectl kustomize manifests/<app>`.
- **echo app** (`examples/echo`, Go stdlib): `go vet ./... && go build ./...`;
  `go run .` then `curl localhost:8080`; `docker build -t echo:dev .`.
- **`echo` and `podinfo` are no longer public.** Both served the open internet with no auth
  until 2026-10-01; their Ingresses are gone and `echo` is now reached in-cluster
  (`kubectl -n echo run t --rm -i --image=curlimages/curl:8.11.1 -- -s http://echo/`). The
  CI→registry→newTag→Argo path is unchanged, so `echo` is still the end-to-end deploy test.
- **Check deploys:** `kubectl -n argocd get applications` (expect `root`, `echo`,
  `podinfo`, `registry` all `Synced/Healthy`). Force a sync with
  `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite`.
- **Argo CD itself is bootstrap-managed, currently v3.5.2.** Upgrade it using
  the complete versioned upstream manifest and the validation procedure in
  `docs/argocd-upgrades.md`; it is not an Application in this repository.

## Commits, branches & PRs

- **`git push` goes to Forgejo** (`git.kiitconsulting.com`), the canonical
  remote. GitHub is a mirror; pushing there loses the commit on the next sync.
- **Every commit must be SIGNED.** Branch protection on `**` sets
  `require_signed_commits`, so an unsigned commit is refused at pre-receive on
  every branch, not just `main`. The key is on the **`git.kiitconsulting.com`**
  item (id `5ccnqojqxn4yyck6hwpyff3u7e`), field `git_signing_private_key`; the
  GitHub key signs fine and Forgejo still calls the result unverified, because it
  is registered on the other account. Verified 2026-10-05:

  ```sh
  export OP_CONFIG_DIR=/tmp/opcfg          # op cannot write its config under /state
  mkdir -p /tmp/gs && chmod 700 /tmp/gs
  op read op://ai-skills/5ccnqojqxn4yyck6hwpyff3u7e/git_signing_private_key > /tmp/gs/fj
  printf '\n' >> /tmp/gs/fj && chmod 600 /tmp/gs/fj
  git -c gpg.format=ssh -c user.signingkey=/tmp/gs/fj -c commit.gpgsign=true \
      -c user.email=9661832+ikscream@users.noreply.github.com commit -m "..."
  ```

  `git log --show-signature` says `No signature` locally for want of an
  `allowedSignersFile`; ignore it and look for a `gpgsig` header in
  `git cat-file commit HEAD`, or ask the API for `verification`.
- **`ai-git` cannot push here.** It resolves credentials for *github.com* and
  fails against `git.kiitconsulting.com` with an authentication error. Use plain
  `git` plus the signing recipe above, and `ai-forgejo` for pull requests.
  `op://ai-skills/forgejo-kiit` is DEAD - no item by that name exists, and the
  helper swallows the lookup, so it offers an empty password that Forgejo reports
  as expired credentials.
- **Branch per task; PR into `main`.** Do not commit product changes straight to
  `main` by hand (CI's tag write-back is the only automated exception).
- **AFTER MERGING, READ `main` BACK.** A merge here can report success and leave
  the branch where it was. Measured 2026-10-05 on PR #29: `merged: true`, a merge
  commit whose parent was the current `main`, and `main` unchanged eighty seconds
  later, so an ai-portal release existed on no branch Argo reads while every tool
  said it had shipped. Cause unknown; signing is ruled out (both that commit and
  the previous merge, which landed, verify). If it did not move, cherry-pick onto
  a fresh `main`, sign, and `git push forgejo main` - direct pushes are allowed
  (`enable_push: true`, empty whitelist).

  ```sh
  curl -s -H "Authorization: token $TOKEN" \
    https://git.kiitconsulting.com/api/v1/repos/ikscream/argo.kiitconsulting.com/branches/main \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["commit"]["id"][:8])'
  ```
- **[Conventional Commits](https://www.conventionalcommits.org/):**
  `type(scope): summary` (`feat`, `fix`, `docs`, `chore`, `ci`, `refactor`).
- **No AI attribution** in commit messages or PR bodies. This is now ENFORCED,
  not merely asked for: `.githooks/commit-msg` rejects the trailer. Turn it on
  once per clone with `git config core.hooksPath .githooks` - hooks are not
  cloned, which is why the script lives in the repo. It exists because prose in
  this file only reaches whoever reads this file: on 2026-10-05 two commits
  landed here with a `Co-Authored-By: Claude` trailer, written by an agent whose
  working directory was another repo, so this file was never in its context and
  its own default instruction won by default.
- Open PRs with `ai-git pr create`; watch CI with `ai-git pr status`.

## Secrets — never commit them

- **Kubernetes Secrets are created out-of-band from 1Password, never in git:**
  `registry-s3` + `registry-auth` (ns `registry`), `registry-pull` (ns `echo`),
  `bayes-postgres` + `registry-pull` (ns `bayes`, from `op://ai-skills/bayes-postgres`),
  `ai-portal-auth` + `ai-portal-claude` + `ai-portal-op` + `ai-portal-s3` +
  `registry-pull` (ns `ai-portal`, from `op://ai-skills/ai-portal-v2` and
  `op://chaineye/aws` § "AI Portal History"), `repo-forgejo-gitops` (ns `argocd`,
  the repository credential Argo CD clones this repo with — `docs/forgejo.md`),
  `forgejo-backup` (ns `forgejo`, the restic passphrase
  `op://ai-skills/forgejo-backup` + the Hetzner S3 keys; **lose it and every
  backup snapshot is unrecoverable** — `docs/forgejo.md`).
  Bootstrap commands live in `docs/ci-cd.md`. Kustomize/Argo manage only the
  non-secret manifests; the app pods depend on these Secrets already existing.
- **References:** S3 keys `op://ai-skills/hetzner/s3` (`s3_access_key`,
  `s3_secret_key`); registry push/pull `op://ai-skills/registry-kiit`; Cloudflare
  DNS token `op://ai-skills/cloudflare-api/api_token`; Argo CD admin
  `op://ai-skills/argocd-kiit`; ai-portal WS cookie key
  `op://ai-skills/ai-portal-v2/ws_cookie_secret`; Forgejo admin plus its
  `argocd` and `ci-writeback` tokens `op://ai-skills/forgejo-kiit`.
- Read secrets at runtime (`op read …`); never echo, log, or commit a value.
  **Actions secrets are per repository in Forgejo** (`PUT
  /api/v1/repos/{o}/{r}/actions/secrets/{name}`) and do **not** come across when
  a repo is migrated — `docs/ci-cd.md` has the loop.
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

- **Certs are Cloudflare DNS-01 now (not HTTP-01).** The `letsencrypt-prod`
  ClusterIssuer uses the DNS-01 solver (`manifests/cert-manager`), so hosts can be
  **grey OR orange (proxied)** — orange is required for Cloudflare Access SSO
  (`docs/cloudflare-access-sso.md`). `argo` + `grafana-k8s` + `ap` are orange + SSO-gated;
  keep `registry` grey (docker/kubelet can't SSO, CF 100 MB upload cap). The old
  "must stay grey" rule is dead.
- **Access at the edge is not a gate at the origin.** Every host resolves to the same node
  IP, so a direct request with the right `Host:` header skips Access entirely. An app with
  its own login survives that; one without (the ai-portal, which treats "no auth configured"
  as "allow everything") does not — it must verify the `Cf-Access-Jwt-Assertion` itself.
  **Since 2026-10-01 orange hosts additionally require Cloudflare's Authenticated Origin
  Pulls client certificate** (`manifests/traefik-origin-mtls` + a `router.tls.options`
  annotation on the Ingress), so the direct path now dies in the TLS handshake. Two rules:
  the zone setting `tls_client_auth` must be **on before** you annotate a router, and
  **never annotate a grey host** — nothing would ever present a cert and it would go dark.
  Don't reach for an IP allowlist instead: ServiceLB SNAT means Traefik sees `10.42.0.1` as
  the client, and `X-Forwarded-For` agrees, for *every* request including Cloudflare's. And
  **`externalTrafficPolicy: Local` does not fix that** — klipper-lb masquerades
  unconditionally and is never told the policy (verified against v0.4.17); only taking Traefik
  off ServiceLB would. Apps behind Cloudflare don't need it anyway (`CF-Connecting-IP` carries
  the true caller); grey hosts like Forgejo are the ones left blind.
  Two consequences when you arm such a gate: **WebSocket paths need a path-scoped `bypass`
  Access app** (an upgrade cannot follow a login redirect), and **`httpGet` probes start
  failing 403** because the kubelet carries no assertion — run the probe inside the pod
  against `127.0.0.1`, which fail-closed origins exempt. Both are worked through in
  `docs/cloudflare-access-sso.md`.
- **Forgejo is deployed by the repo Forgejo serves.** If its pod or PVC dies,
  Argo CD can reach no source at all and the cluster freezes as-is — running
  workloads keep running, but nothing can be changed through git. Break-glass is
  to patch every Application's `repoURL` back to the GitHub mirror; the exact
  commands, and the trap that `root` will self-heal your patches away, are in
  `docs/forgejo.md`. Don't deepen the loop by moving more of the control plane
  behind Forgejo.
- **Don't hand-edit `manifests/echo/kustomization.yaml` `newTag`** — CI owns it.
  The write-back commit is SSH-signed using Actions secret `GIT_SIGNING_KEY`
  and the trusted `ikscream` committer identity, uses `[skip ci]`,
  and the workflow's `paths:` filter prevents a build loop. It pushes with
  `GITOPS_TOKEN`, not the job's own token, which is scoped to one repository —
  and not `FORGEJO_TOKEN`, a name Forgejo refuses to store.
- **Workflows live in `.forgejo/workflows/`, and Forgejo falls back to
  `.github/workflows/` when that directory is absent.** So a repo migrated here
  with its GitHub directory intact starts running those workflows on the
  in-cluster runner immediately — usually failing on Actions secrets it was
  never given, since **secrets do not migrate with a repository**. Move the
  directory rather than copying it, or GitHub and Forgejo both build every
  commit.
- **After a CI build, `origin/main` is ahead** of your local by the write-back
  commit — fetch/rebase before branching.
- **Real client IP is not preserved** — Traefik/k3s ServiceLB SNAT means `echo`
  reports the internal hop (`10.42.0.x`). Set the Traefik service
  `externalTrafficPolicy: Local` (or PROXY protocol) if you need true client IPs.
- **Registry auth returns 401 on `/v2/`**, so its probes are `tcpSocket`, not
  HTTP. Push/pull needs the `ci` basic-auth creds.
