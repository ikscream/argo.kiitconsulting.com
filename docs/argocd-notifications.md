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

| Trigger | When | Subscribed? |
|---|---|---|
| `on-sync-failed` | sync Error/Failed | ✅ |
| `on-health-degraded` | health Degraded | ✅ |
| `on-sync-status-unknown` | sync status Unknown | ✅ |
| `on-deployed` | sync Succeeded **and** Healthy | ❌ (defined, not subscribed) |
| `on-sync-succeeded` | sync operation Succeeded | ❌ (defined, not subscribed) |

**Only failures/degradation are subscribed** — the actionable events. Success and
deploy pings are deliberately off: with **app-of-apps GitOps every commit** (incl.
unrelated CI image-tag write-backs) bumps the tracked revision for *all* apps, so
`on-deployed`/`on-sync-succeeded` re-fire for every app on every push and spam the
channel. The two success triggers/templates are still defined, so you can
re-subscribe them (ideally **per-app** via a
`notifications.argoproj.io/subscribe.on-deployed.telegram` annotation on the
Application you care about, not the global default) if you want deploy pings.

`on-sync-running` is also omitted (too noisy) — add a trigger/template + subscribe
if you want per-sync-start pings.

## Notes

- **We use a `webhook` service, not the built-in `telegram` one.** Argo CD's
  telebot-based telegram notifier returns `Bad Request: chat not found` for
  private-user chats (the token + chat are fine — a direct Bot API call works).
  So `service.webhook.telegram` POSTs to
  `https://api.telegram.org/bot$telegram-token/sendMessage` directly; the
  subscription recipient is just `telegram` and the `chat_id` lives in the body.
- Template bodies build the message text with `printf … | toJson` so newlines and
  special characters (e.g. a sync-failure message) are always safely JSON-escaped.
- Templates use Argo's Go-template context (`{{.app...}}`, `{{.context.argocdUrl}}`)
  in a plain ConfigMap (kustomize, not Helm), so the braces are safe — unlike the
  Grafana chart, which runs values through Helm `tpl`.
- **selfHeal note:** this CM is managed by the `argocd-notifications` Application,
  so a live `kubectl edit`/`apply` is reverted within minutes — change it via git.
