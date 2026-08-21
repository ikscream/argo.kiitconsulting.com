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

Dashboards are organized into folders: **Kubernetes / Views** (15757/15759/15760),
**Nodes** (1860), and **Kubernetes / Mixin** (the chart's bundled dashboards, moved
out of General via `grafana.sidecar.dashboards.provider.folder`). To add more, drop
another entry under `grafana.dashboards.<provider>` (bump `revision` to the latest
from `https://grafana.com/api/dashboards/<id>`).

## Alerting (Grafana-managed → Telegram)

All IaC under `grafana.alerting` in `apps/monitoring.yaml`:

- **Contact point `Telegram`** → bot `@kiitconsulting_bot`, chat `194219638`. The
  bot token is injected via the `TELEGRAM_BOTTOKEN` env var (from the
  `grafana-telegram` Secret) and referenced as `$__env{TELEGRAM_BOTTOKEN}` — never
  in git. The default notification policy routes everything to `Telegram`.
- **Rule folders** (best-practice Kubernetes alerts):
  - `Kubernetes / Nodes` — CPU >85%, memory >90%, root disk >85%, NotReady, OOM kills
  - `Kubernetes / Workloads` — crash-looping, container OOMKilled, prolonged NotReady, deployment replica mismatch
  - `Kubernetes / Storage` — PVC >85% full
  - `Kubernetes / Cluster` — scrape target down
- Alerts carry static descriptions; the firing instance's labels (namespace/pod/
  node/instance) appear in the Telegram message.
- **Custom HTML message template** on the contact point (`settings.message`,
  `parse_mode: HTML`): firing/resolved header + per-alert emoji, name, severity,
  description, 📦 namespace/pod, 🖥 instance, 📊 `.ValueString`, 🕐 time.

### Two gotchas learned the hard way (both in `apps/monitoring.yaml`)

- **The chart runs `grafana.alerting` values through Helm `tpl`.** So `{{ ... }}`
  meant for Grafana breaks the render. Alert-rule annotations therefore avoid
  `{{ }}` entirely; the message template wraps its Grafana `{{ }}` in a Helm
  **backtick raw-string** (`` message: | {{ `<grafana template>` }} ``) so `tpl`
  passes it through literally.
- **Use `.ValueString`, not `{{ range $k, $v := .Values }}`.** Grafana's
  notification template engine rejects the two-variable `range` (`unexpected ","
  in range`) → the message fails to template and Telegram returns 400 (nothing
  delivered). This only shows up on a *real* firing alert, so test with one.

**Testing / "no alerts in Telegram" is usually normal:** if all rules are
`inactive`, the cluster is healthy and there is nothing to send. To force a real
alert, provision a temporary always-firing rule (`expr: vector(1)`, threshold
`gt 0`) via `POST /api/v1/provisioning/alert-rules` (header
`X-Disable-Provenance: true`), confirm delivery, then `DELETE` it — the
contact-point *Test* button/endpoint does **not** exercise a custom
`settings.message`.

## Sizing note (cx33, 4 vCPU / 8 GB)

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
# Telegram bot token for the alert contact point
kubectl -n monitoring create secret generic grafana-telegram \
  --from-literal=bottoken="$(op read op://ai-skills/wq2n2roohzy3aqod22tecundri/password)"
```
