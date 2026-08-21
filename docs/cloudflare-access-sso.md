# Cloudflare Access (SSO) for cluster services

Some cluster UIs are put behind **Cloudflare Access** — an SSO gate at Cloudflare's
edge. A request to the hostname is intercepted by Cloudflare, the user logs in via
an identity provider (Google or one-time-PIN), and only allowed identities reach
the origin.

## Currently gated

| Host | Access app | Allowed |
|---|---|---|
| `argo.kiitconsulting.com` | "Argo CD" | `ivanov.konstantin.89@gmail.com` |
| `grafana-k8s.kiitconsulting.com` | "Grafana (k8s)" | `ivanov.konstantin.89@gmail.com` |

Team domain: `silent-grass-7cb0.cloudflareaccess.com`. IdPs configured: **Google**
+ one-time-PIN. Access apps live in Cloudflare (Zero Trust), not in this repo.

## How it works (and why grey ≠ SSO)

Cloudflare Access can only enforce on **proxied (orange)** hostnames — traffic has
to pass through Cloudflare's edge. Our default apps are **DNS-only (grey)**, so
they bypass Cloudflare entirely and Access never sees them. To gate a host you
must flip it to **orange**.

```
Browser ──▶ Cloudflare edge (Access: SSO login) ──▶ Traefik ingress ──▶ Service
              only allowed identities pass
```

### The one prerequisite: DNS-01 certificates

Behind Access, the Let's Encrypt **HTTP-01** challenge fails — Access intercepts
`/.well-known/acme-challenge/...` with the SSO login page. So the shared
`letsencrypt-prod` ClusterIssuer uses the **Cloudflare DNS-01** solver
([`manifests/cert-manager/clusterissuer.yaml`](../manifests/cert-manager/clusterissuer.yaml),
deployed by `apps/cert-manager-issuer.yaml`). DNS-01 needs no inbound HTTP, so it
works for grey and orange hosts alike. Token scopes required: **Zone:DNS:Edit** +
**Zone:Zone:Read** (the `cloudflare-api-token` Secret in `cert-manager`,
out-of-band from 1Password).

## Can other Kubernetes services do this? — Yes

**Any service that already has a public HTTPS Ingress** (the standard
`cert-manager.io/cluster-issuer: letsencrypt-prod` + Traefik `websecure` pattern)
can be SSO-gated with **no changes to the app or its manifests** — Access is an
edge concern. Two steps:

```sh
# 1. create the Access app + allow-policy AND flip the host to orange:
scripts/cf-access-app.sh "My App" myapp.kiitconsulting.com ivanov.konstantin.89@gmail.com

# (add more allowed emails as extra args; or use a whole domain in the dashboard)
```

That's it. The script creates the Access application, an allow-policy for the
listed email(s), and sets the DNS record to proxied. The service keeps its own
login too (Access is an additional outer layer).

### Do it by hand instead

1. Ensure the host has a working HTTPS Ingress + cert (it will renew via DNS-01).
2. Cloudflare **Zero Trust → Access → Applications → Add → Self-hosted**, domain =
   the host, add a policy **Allow → Emails → your address**.
3. Flip the host's DNS record to **orange (proxied)**.

## What should NOT be gated

- **`registry.kiitconsulting.com`** — docker/kubelet can't do interactive SSO, and
  Cloudflare's free proxy caps uploads at **100 MB** (breaks image pushes). Keep it
  **grey**.
- Anything consumed by machines (APIs, webhooks, `bayes-ingest` if scraped) — use a
  **service token** or **bypass policy** for those paths instead of a login.

## Caveats

- **Origin-IP bypass:** grey and orange share the same origin IP. Someone who knows
  `178.104.210.183` and sends the right `Host:` header can reach a gated app's
  origin directly, past Access. The apps still have their own login, so this is
  defense-in-depth — but to close it, restrict the origin firewall to Cloudflare's
  IP ranges (only viable once *all* public hosts are orange) and/or enable
  **Authenticated Origin Pulls** (mTLS Cloudflare↔origin). Not done yet because
  grey hosts (echo, podinfo, registry, bayes-ingest) still need direct access.
- **Keep gated hosts orange.** Flipping one back to grey silently removes the SSO
  gate.
- Zone SSL mode is **Full (strict)** — the edge validates the origin's real LE
  cert. Grey hosts bypass Cloudflare, so the mode does not affect them.
