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
| `ap.kiitconsulting.com` | "ai-portal v2 (console)" | `ivanov.konstantin.89@gmail.com` |
| `ap.kiitconsulting.com/ws` | "ai-portal v2 /ws (bypass)" | everyone — **bypass**, see below |
| `ap.kiitconsulting.com/dispatch` | "ai-portal v2 /dispatch (bypass)" | everyone — **bypass**, see below |

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

### WebSockets need a path-scoped bypass app

An Access challenge is an **HTTP 302 to a login page**, and a WebSocket upgrade cannot
follow one — so gating a host that serves WebSockets breaks every socket on it. Cloudflare
resolves overlapping apps **most-specific-path-first**, so the fix is a second app scoped to
the socket path whose policy is `bypass`; it wins over the root app's `allow`. That is what
`ap.kiitconsulting.com/ws` and `/dispatch` are (the portal gates both itself: a signed
cookie / `?t=` token for browsers, a Bearer `DISPATCH_TOKEN` for dispatchers).

`scripts/cf-access-app.sh` only does the `allow` case. Create a bypass app directly:

```sh
CF="$(op read 'op://ai-skills/cloudflare-api/api_token')"
ACCT=e51f67e175a1477e8cc239f9247f3250
APP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCT/access/apps" \
  -H "Authorization: Bearer $CF" -H 'Content-Type: application/json' \
  -d '{"name":"myapp /ws (bypass)","type":"self_hosted","domain":"myapp.kiitconsulting.com/ws","session_duration":"24h"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["id"])')
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCT/access/apps/$APP/policies" \
  -H "Authorization: Bearer $CF" -H 'Content-Type: application/json' \
  -d '{"name":"bypass-everyone","decision":"bypass","include":[{"everyone":{}}]}' >/dev/null
```

Create the bypass apps **before** the root `allow` app, so there is never a window where a
live socket path is challenged.

## Verifying the assertion at the origin (closing the origin-IP bypass)

Edge SSO alone is **not** an origin gate. Grey and orange hosts share this node's IP, so a
request sent straight to `178.104.210.183` with the right `Host:` header never touches
Cloudflare and never meets Access. For apps with their own login (Argo CD, Grafana) that is
just defense-in-depth. For one with **no** login of its own it is the whole gate — the
ai-portal treats "nothing configured" as "allow everything", so edge-only would have left it
open to anyone who knows the IP.

Access stamps every admitted request with a signed `Cf-Access-Jwt-Assertion`. An origin that
**verifies** it (RS256 against `https://<team>/cdn-cgi/access/certs`, plus `iss`, `exp`/`nbf`
and **`aud`**) turns the edge's identity into a real gate. The portal does this natively —
`PORTAL_ACCESS_TEAM_DOMAIN` + `PORTAL_ACCESS_AUD` in
[`manifests/ai-portal/deployment.yaml`](../manifests/ai-portal/deployment.yaml); both are
required or the gate stays off. Find an app's `aud` with
`GET /accounts/<acct>/access/apps`; it is not a secret (it is the `kid=` parameter in the
public login redirect) but it **is** load-bearing: the team JWKS signs tokens for *every*
app in the Zero Trust account, so skipping the `aud` check lets an Argo CD or Grafana token
open the portal.

**This breaks `httpGet` health probes.** The kubelet dials the pod IP from the node with no
assertion and no `CF-Connecting-IP`, which a fail-closed origin rejects — measured: HTTP 403,
so liveness fails every period and a healthy pod CrashLoops. The portal exempts **loopback**
callers for exactly this reason (a request that never reached the edge cannot carry a JWT the
edge would have stamped), so run the probe *inside* the container against `127.0.0.1`:

```yaml
livenessProbe:
  exec:
    command: [node, -e, "require('http').get('http://127.0.0.1:8787/api/version',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
```

Prefer that over `tcpSocket`, which passes on a wedged server that still accepts connections.

## What should NOT be gated

- **`registry.kiitconsulting.com`** — docker/kubelet can't do interactive SSO, and
  Cloudflare's free proxy caps uploads at **100 MB** (breaks image pushes). Keep it
  **grey**.
- Anything consumed by machines (APIs, webhooks, `bayes-ingest` if scraped) — use a
  **service token** or **bypass policy** for those paths instead of a login.
- **WebSocket paths** — see the bypass recipe above; a login redirect is unfollowable by a
  socket.

## Caveats

- **Origin-IP bypass:** grey and orange share the same origin IP. Someone who knows
  `178.104.210.183` and sends the right `Host:` header can reach a gated app's
  origin directly, past Access. `argo` and `grafana-k8s` still have their own login, so for
  them this is defense-in-depth; `ap` closes it properly by verifying the assertion at the
  origin (see above), which is the general fix for an app with no login of its own.
  Cluster-wide alternatives: restrict the origin firewall to Cloudflare's IP ranges (only
  viable once *all* public hosts are orange) and/or enable **Authenticated Origin Pulls**
  (mTLS Cloudflare↔origin). Not done yet because grey hosts (echo, podinfo, registry,
  bayes-ingest) still need direct access.
- **Don't reach for an IP allowlist on this cluster.** An origin allowlist has to read the
  client address from `CF-Connecting-IP`, which is only trustworthy when Cloudflare is the
  sole path in. Here the origin is directly reachable, so a caller can set that header
  themselves — the allowlist would be a gate anyone can walk through. Verify identity
  instead.
- **Keep gated hosts orange.** Flipping one back to grey silently removes the SSO
  gate.
- Zone SSL mode is **Full (strict)** — the edge validates the origin's real LE
  cert. Grey hosts bypass Cloudflare, so the mode does not affect them.
