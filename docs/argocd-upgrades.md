# Argo CD upgrades

Argo CD itself is installed outside this application repository by the
`ai-hetzner/provisioning` bootstrap. It cannot safely manage its own complete
installation through the app-of-apps tree, so version upgrades remain an
explicit cluster-administration operation.

## Current version

Argo CD was upgraded from `v3.5.1` to `v3.5.2` on 2026-09-07. The complete
upstream non-HA manifest was applied, including CRDs and RBAC. The manifest also
updated Dex from `v2.45.0` to `v2.45.1`; Redis remained at `8.2.3-alpine`.

After the rollout, all Argo CD Deployments and the application-controller
StatefulSet were Ready. Every managed Application reported `Synced/Healthy`,
the ingress and `server.insecure=true` customization remained present, and the
server/repo-server logs contained no error, fatal, or panic entries from the
upgrade window.

## Procedure

Read every intervening official upgrade note for minor or major upgrades. For
a patch upgrade, still use the complete versioned manifest rather than changing
only container images:

```sh
kubectl apply -n argocd --server-side --force-conflicts --dry-run=server \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml
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

Official references: [release v3.5.2](https://github.com/argoproj/argo-cd/releases/tag/v3.5.2)
and [upgrade overview](https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/overview/).
