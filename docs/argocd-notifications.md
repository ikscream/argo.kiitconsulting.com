# Argo CD notifications → Telegram

Argo CD's built-in **notifications controller** (shipped with the install) posts
deploy/sync/failure/health events for **every** Application to Telegram
(`@kiitconsulting_bot`, chat `194219638`).

- Config: [`manifests/argocd-notifications/configmap.yaml`](../manifests/argocd-notifications/configmap.yaml)
  (`argocd-notifications-cm`), deployed by `apps/argocd-notifications.yaml` with
  `ServerSideApply=true` so Argo adopts the ConfigMap the install created.
- **Token is out-of-band** in `argocd-notifications-secret` (key `telegram-token`),
  never in git:
  ```sh
  kubectl -n argocd patch secret argocd-notifications-secret --type merge \
    -p "{\"stringData\":{\"telegram-token\":\"$(op read op://ai-skills/wq2n2roohzy3aqod22tecundri/password)\"}}"
  ```

## What fires

A **default subscription** (in the CM) sends these to Telegram for all apps — no
per-app annotations needed:

| Trigger | When |
|---|---|
| `on-deployed` | sync Succeeded **and** Healthy (once per revision) |
| `on-sync-succeeded` | sync operation Succeeded |
| `on-sync-failed` | sync Error/Failed |
| `on-health-degraded` | health Degraded |
| `on-sync-status-unknown` | sync status Unknown |

`on-sync-running` is intentionally omitted (too noisy); add it to the CM's
`subscriptions` + a `trigger.on-sync-running`/`template.app-sync-running` if you
want per-sync-start pings.

## Notes

- Templates use Argo's own Go-template context (`{{.app...}}`, `{{.context.argocdUrl}}`).
  These live in a plain ConfigMap (kustomize, not Helm), so the braces are safe —
  unlike the Grafana chart, which runs values through Helm `tpl`.
- Recipient format is `telegram:<chatid>`; the token comes from the secret.
