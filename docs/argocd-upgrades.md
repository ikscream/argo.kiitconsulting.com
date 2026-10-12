# Argo CD upgrades

Argo CD itself is installed outside this application repository by the
`ai-hetzner/provisioning` bootstrap. It cannot safely manage its own complete
installation through the app-of-apps tree, so version upgrades remain an
explicit cluster-administration operation.

## Current version

Argo CD was upgraded from `v3.5.2` to `v3.5.5` on 2026-10-12. The complete
upstream non-HA manifest was applied, including CRDs and RBAC; Dex stayed at
`v2.45.1` and Redis at `8.2.3-alpine`, so the only images that moved were the
five running `quay.io/argoproj/argocd`.

**This was a security upgrade, not housekeeping.** `v3.5.4` fixes four CRITICAL
advisories, three of which are code execution or file reads *in the repo-server*
— the component that renders every Application here, from a Helm chart
(`monitoring`) and from Kustomize directories in this repo:

| | |
|---|---|
| CRITICAL | a Kustomize remote ref can run commands in the repo-server ([GHSA-9v9p-x54c-58gc](https://github.com/argoproj/argo-cd/security/advisories/GHSA-9v9p-x54c-58gc)) |
| CRITICAL | a Kustomize Helm config home can run commands in the repo-server ([GHSA-fw5c-w8rc-j7fx](https://github.com/argoproj/argo-cd/security/advisories/GHSA-fw5c-w8rc-j7fx)) |
| CRITICAL | a Jsonnet import can read files from the repo-server ([GHSA-m3vr-7329-44ww](https://github.com/argoproj/argo-cd/security/advisories/GHSA-m3vr-7329-44ww)) |
| CRITICAL | AppProject restrictions bypassed by PreDelete/PostDelete hooks (CVE-2026-77459) |
| HIGH | login failure rate limit bypassed by concurrent requests (CVE-2025-61560) |
| HIGH | command injection via a repository proxy URL on SSH Git repos (CVE-2026-55797) |

`v3.5.5` adds the rest of the fixes on that branch, including an untar check for
a symlinked destination path.

Verified after the rollout, in this order:

- all six Deployments and the application-controller StatefulSet Ready, every
  `argocd` image on `v3.5.5`;
- the two customisations survived the `--force-conflicts` apply —
  `argocd-cmd-params-cm` still carries `server.insecure: "true"` (the
  server-side dry run was checked for this *before* applying, since
  `--force-conflicts` is exactly the flag that could drop it) and the
  `argo.kiitconsulting.com` ingress still holds `argocd-server-tls`;
- all **12** Applications `Synced/Healthy`, the same set as before;
- `argocd-server`, `argocd-repo-server` and `argocd-application-controller`
  logged **zero** error, fatal or panic lines in the upgrade window;
- `GET /api/version` through the in-cluster Service answered `v3.5.5`, which is
  the API the UI calls rather than the `/healthz` the probes call.

## Procedure

Read every intervening official upgrade note for minor or major upgrades. For
a patch upgrade, still use the complete versioned manifest rather than changing
only container images:

```sh
kubectl apply -n argocd --server-side --force-conflicts --dry-run=server \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
```

Then wait for these workloads and inspect every Application:

```sh
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
kubectl -n argocd get deploy,statefulset
kubectl -n argocd get applications
```

The complete list also includes the ApplicationSet, Dex, notifications, and
Redis Deployments. Confirm their images and readiness rather than assuming the
three representative rollout checks cover them.

`--force-conflicts` takes ownership of every field the upstream manifest names,
so the server-side **dry run is where you check that a local customisation
survives** — not the rollout. Grep its output for the setting before applying
for real; `server.insecure` appeared in the merged result, which is what made
the apply safe.

Official references: [release v3.5.5](https://github.com/argoproj/argo-cd/releases/tag/v3.5.5)
and [upgrade overview](https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/overview/).
