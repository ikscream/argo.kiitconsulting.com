# k3s upgrades

k3s is the cluster, so upgrading it is the one operation here with no blast
radius smaller than "everything". It is installed by the `ai-hetzner/provisioning`
bootstrap on the single `k3s-argocd` node, with a deliberately minimal unit —
`ExecStart=/usr/local/bin/k3s server --write-kubeconfig-mode 644` — and a
**sqlite** datastore at `/var/lib/rancher/k3s/server/db/state.db`, because one
node needs no etcd.

**Traefik comes with it.** The ingress controller is the HelmChart k3s serves
from its own API server (`/var/lib/rancher/k3s/server/manifests/traefik.yaml`,
`https://%{KUBERNETES_API}%/static/charts/traefik-<v>.tgz`). There is no separate
Traefik upgrade and no `HelmChartConfig` overriding it here: bumping k3s is how
Traefik moves. Our only Traefik customisation is the `TLSOption` in
`manifests/traefik-origin-mtls/`, which is an Argo-managed object and survives a
chart bump untouched.

## Current version

Upgraded from `v1.36.3+k3s1` to `v1.36.5+k3s1` on 2026-10-12, which carried
**Traefik 3.7.8 → 3.7.13** and containerd `v2.3.4-k3s1.36`. The release also
bumps gRPC for CVE-2026-84445 and fixes the deploy controller failing to
re-apply manifests whose mtime is pinned to the epoch.

**Stayed in the 1.36 line on purpose.** `v1.37.1+k3s1` exists, but a minor jump
moves the API server under twelve Applications, cert-manager's CRDs and the
Prometheus operator at once; a patch release keeps the Kubernetes minor fixed
and still delivered the Traefik patches that were the reason to do it. Take
minors one at a time, in their own window.

Measured on the day:

- the API answered `/readyz` **10 seconds** after `systemctl start k3s`, and the
  node reported `v1.36.5+k3s1` / `Ready` on the first poll after that;
- running pods **were not restarted** by the upgrade — stopping k3s leaves the
  containerd shims alive, which is why this is a restart and not an outage.
  `k3s-killall.sh` is the thing that would have killed them, and it is not part
  of this procedure;
- Traefik rolled itself ~90 seconds later, chart `40.1.4+up40.1.0` →
  `40.1.5+up40.1.0`, image `3.7.8` → `3.7.13`, one replica ready throughout;
- all **12** Applications stayed `Synced/Healthy`;
- end-to-end through Cloudflare: `git` and `registry` 200, `ap` and `argo` 302 to
  the Access login, Grafana `/api/health` 200 with its Access service token —
  which also proves origin mTLS still works after the Traefik bump.

## Procedure

Swap the binary. Do **not** re-run `get.k3s.io` unless you pass the original
flags: the installer regenerates the systemd unit, and this one carries
`--write-kubeconfig-mode 644` that nothing else would put back.

```sh
# 1. Stage and VERIFY the target binary before touching the running one.
V=v1.36.5+k3s1; VE=v1.36.5%2Bk3s1
curl -sfL -o /root/k3s.new "https://github.com/k3s-io/k3s/releases/download/${VE}/k3s"
curl -sfL -o /root/k3s.sha "https://github.com/k3s-io/k3s/releases/download/${VE}/sha256sum-amd64.txt"
grep -E '[[:space:]]k3s$' /root/k3s.sha | awk '{print $1}'   # published
sha256sum /root/k3s.new | awk '{print $1}'                   # must match

# 2. The window. Stopping k3s first is what makes the sqlite copy consistent —
#    state.db is in WAL mode, so a copy taken while it runs is torn.
systemctl stop k3s
B=/root/k3s-backup-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$B"
cp -a /var/lib/rancher/k3s/server/db/state.db* /var/lib/rancher/k3s/server/token "$B"/
cp -a /usr/local/bin/k3s "$B"/k3s.$(k3s --version | head -1 | awk '{print $3}')
cp -a /usr/local/bin/k3s /usr/local/bin/k3s.rollback
install -m 0755 /root/k3s.new /usr/local/bin/k3s
systemctl start k3s
```

Then verify, in this order — each line answers a different question:

```sh
k3s kubectl get --raw /readyz                       # the API is back
k3s kubectl get node -o wide                        # kubeletVersion is the new one, Ready
k3s kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
k3s kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].image}'
k3s kubectl -n argocd get applications              # every one Synced/Healthy
```

and from outside, because an ingress that resolves on the node proves less than
one that resolves through Cloudflare:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://git.kiitconsulting.com/        # 200
curl -s -o /dev/null -w '%{http_code}\n' https://ap.kiitconsulting.com/         # 302 to Access
```

**A direct origin request is not a health check.** From the node,
`grafana-k8s` and `argo` fail the TLS handshake outright and `ap` returns 403 —
that is Authenticated Origin Pulls and the Access JWT check doing their job, not
a broken ingress. Test through Cloudflare, or with the Access service token on
`op://ai-skills/grafana-k8s.kiitconsulting.com`.

## Rollback

`/usr/local/bin/k3s.rollback` is the previous binary and `$B` holds the sqlite
datastore as it was. Rolling back is `systemctl stop k3s`, restore both, start.
Restoring the datastore is only needed if a *minor* upgrade migrated it; a patch
does not.

## Afterwards

A k3s upgrade pulls new images and leaves the old ones. `k3s crictl rmi --prune`
removes everything no container references — on 2026-10-12 that was the Traefik
3.7.8 image and the superseded portal and CoreDNS tags. Worth doing: containerd
is the largest single consumer of the 38 GB root disk (13 GB after the prune),
and that disk is this cluster's recurring failure mode.
