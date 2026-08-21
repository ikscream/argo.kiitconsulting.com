# Monitoring — Prometheus Operator + Grafana

Deployed by [`apps/monitoring.yaml`](../apps/monitoring.yaml) via the
[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
Helm chart (Argo CD Helm-source Application, chart `88.5.3`). Everything is IaC.

## What you get

- **Prometheus Operator** + a **Prometheus** (namespace `monitoring`, internal
  only — no public ingress).
- **Grafana** at **<https://grafana-k8s.kiitconsulting.com>** (Traefik + Let's
  Encrypt). Admin: `admin` / `op://ai-skills/grafana-kiit`.
- **kube-state-metrics** + **node-exporter** for cluster/node metrics.
- **Alertmanager is disabled** to save memory on the single node.

> Why `grafana-k8s` and not `grafana`? `grafana.kiitconsulting.com` is already a
> Cloudflare Tunnel CNAME to a different Grafana — left untouched.

## Grafana is wired to this Prometheus

The chart's Grafana sidecar auto-provisions the in-cluster Prometheus as the
default datasource named **`Prometheus`** — no manual datasource config.

## Dashboards (imported from grafana.com by ID)

Provisioned into a **Kubernetes** folder, using the `Prometheus` datasource:

| ID | Dashboard | Rev |
|---|---|---|
| [15757](https://grafana.com/grafana/dashboards/15757) | Kubernetes / Views / Global | 43 |
| [15759](https://grafana.com/grafana/dashboards/15759) | Kubernetes / Views / Nodes | 40 |
| [15760](https://grafana.com/grafana/dashboards/15760) | Kubernetes / Views / Pods | 39 |
| [1860](https://grafana.com/grafana/dashboards/1860) | Node Exporter Full | 45 |

The chart's own default Kubernetes dashboards are also enabled. To add more, drop
another entry under `grafana.dashboards.grafana-com` in `apps/monitoring.yaml`
(bump `revision` to the latest from `https://grafana.com/api/dashboards/<id>`).

## Sizing note (single 2 vCPU / 4 GB node)

Tuned to fit: Alertmanager off; Prometheus `retention: 12h`, `memory ≤ 900Mi`,
5Gi local-path PVC; k3s-unscrapeable control-plane monitors
(`kubeControllerManager/Scheduler/Proxy/Etcd`) disabled. If the node gets memory
pressure, lower Prometheus retention/limits first.

## Secret bootstrap (out-of-band)

```sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(op read op://ai-skills/grafana-kiit/password)"
```
