# Adding an application

Argo CD watches [`apps/`](../apps) recursively (via the app-of-apps root). To
deploy something new you add two things and push — no `kubectl` needed.

## 1. Add the workload manifests

Create `manifests/<name>/` with your Kubernetes resources and a
`kustomization.yaml`. Example for a service called `hello`:

```
manifests/hello/
├── deployment.yaml
├── service.yaml
└── kustomization.yaml
```

`kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

Don't pin the namespace in the manifests — the Application sets it (next step).

## 2. Add the Argo CD Application

Copy [`apps/podinfo.yaml`](../apps/podinfo.yaml) to `apps/hello.yaml` and change
`metadata.name`, `spec.source.path`, and `spec.destination.namespace`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ikscream/argo.kiitconsulting.com.git
    targetRevision: main
    path: manifests/hello
  destination:
    server: https://kubernetes.default.svc
    namespace: hello
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
```

## 3. Push

```sh
git add apps/hello.yaml manifests/hello
git commit -m "feat(hello): add hello app"
git push
```

Within a few minutes (or click **Refresh** in the UI) Argo CD creates the
`hello` Application and syncs it. Watch it:

```sh
kubectl -n argocd get applications
kubectl -n argocd get application hello -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
```

## Notes

- **Sources other than Kustomize:** point `spec.source.path` at a directory of
  plain YAML (Argo CD auto-detects), or use `spec.source.helm` / a Helm chart
  repo. The pattern is identical.
- **Deploying to another cluster:** register it in Argo CD
  (`argocd cluster add <context>`) and set `spec.destination.server` to that
  cluster's API URL instead of `https://kubernetes.default.svc`.
- **Removing an app:** delete its `apps/<name>.yaml` and push — the finalizer
  prunes the workload. Remove `manifests/<name>/` in the same commit.
- **Ordering / dependencies:** use
  [sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
  (`argocd.argoproj.io/sync-wave` annotation) when resources must apply in order.
