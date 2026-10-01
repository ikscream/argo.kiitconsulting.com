# Cloudflare Access (SSO) for cluster services

Some cluster UIs are put behind **Cloudflare Access** — an SSO gate at Cloudflare's
edge. A request to the hostname is intercepted by Cloudflare, the user logs in via
an identity provider (Google or one-time-PIN), and only allowed identities reach
the origin.

## Currently gated

| Host | Access app | Allowed | Gate at the origin |
|---|---|---|---|
| `argo.kiitconsulting.com` | "Argo CD" | `ivanov.konstantin.89@gmail.com` | **origin mTLS** |
| `grafana-k8s.kiitconsulting.com` | "Grafana (k8s)" | `ivanov.konstantin.89@gmail.com` | **origin mTLS** |
| `ap.kiitconsulting.com` | "ai-portal v2 (console)" | `ivanov.konstantin.89@gmail.com` | JWT verified in-app |
| `ap.kiitconsulting.com/ws` | "ai-portal v2 /ws (bypass)" | everyone — **bypass**, see below | signed cookie / `?t=` |
| `ap.kiitconsulting.com/dispatch` | "ai-portal v2 /dispatch (bypass)" | everyone — **bypass**, see below | Bearer `DISPATCH_TOKEN` |

Team domain: `silent-grass-7cb0.cloudflareaccess.com`. IdPs configured: **Google**
+ one-time-PIN. Access apps live in Cloudflare (Zero Trust), not in this repo.

Every orange host now has a gate at the **origin** as well as at the edge — see
[Closing the origin-IP bypass](#closing-the-origin-ip-bypass-authenticated-origin-pulls).
Two stale bypass apps for the decommissioned v1 host `ai.kiitconsulting.com` were deleted on
2026-10-01 (NXDOMAIN, and no record of any type for it in the zone).

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

## Closing the origin-IP bypass: Authenticated Origin Pulls

Verifying the assertion in-app (above) only works for an app you control the code of. Argo CD
and Grafana are upstream software, and on 2026-10-01 a probe showed exactly how little the
edge was buying us:

```
$ curl -k --resolve argo.kiitconsulting.com:443:178.104.210.183 https://argo.kiitconsulting.com/
200   ← the Argo CD UI, Access never in the path
$ curl -k --resolve ... -X POST .../api/v1/session -d '{"username":"admin","password":"wrong"}'
401   ← the login API answering the open internet
```

With `admin.enabled` unset (Argo CD defaults it to **true**) and no `dex.config`/`oidc.config`,
that one password was the entire perimeter. The origin IP is not obscure either — `git`,
`registry`, `echo` and `podinfo` all published it in this zone's public DNS.

**The fix: make Cloudflare prove it is Cloudflare, with a client certificate.**

1. **Zone setting** (once, account-wide for proxied traffic):
   ```sh
   curl -X PATCH -H "Authorization: Bearer $CF" -H 'Content-Type: application/json' \
     --data '{"value":"on"}' \
     "https://api.cloudflare.com/client/v4/zones/$ZONE/settings/tls_client_auth"
   ```
   Cloudflare now presents its Origin Pull client cert on every proxied request. On its own
   this changes nothing — no origin asks for the cert yet. **Do this first**; arming Traefik
   before the zone setting is on takes the host down through Cloudflare too.
2. **Trust anchor + TLS policy**: `manifests/traefik-origin-mtls/` (Application
   `apps/traefik-origin-mtls.yaml`) holds Cloudflare's public Origin Pull CA and a Traefik
   `TLSOption` with `clientAuthType: RequireAndVerifyClientCert`.
3. **Arm one router** by annotating its Ingress:
   ```yaml
   traefik.ingress.kubernetes.io/router.tls.options: kube-system-cloudflare-origin-pull@kubernetescrd
   ```
   Grafana's lives in `apps/monitoring.yaml` (chart values); Argo CD's in
   `bootstrap/argocd-ingress.yaml`, which is **hand-applied** because Argo CD is
   bootstrap-managed and not an Application here.

A request that does not present the cert now dies in the TLS handshake, before there is an
HTTP request to route:

| | via Cloudflare | direct to `178.104.210.183` |
|---|---|---|
| `argo` | 302 → Access login | **curl exit 55**, connection reset |
| `grafana-k8s` | 302 → Access login | **curl exit 56**, connection reset |
| `ap` (not armed) | 302 → Access login | 403 (verifies the JWT itself) |

**Arm it per host, never zone-wide at Traefik.** Grey hosts must not carry the annotation:
they never pass through Cloudflare, so nothing would ever present a cert and they would become
unreachable. That is why `registry` — which cannot be proxied at all, see below — keeps a plain
TLS router.

**Failure direction.** If `apps/traefik-origin-mtls.yaml` is pruned, the annotations dangle and
Traefik falls back to its default TLS config: the gate fails **open** and the UIs stay up.
That is deliberate. A gate that fails closed on a bad sync would lock you out of the very tool
you repair syncs with.

**To revert one host** (e.g. to debug from outside Cloudflare):
```sh
kubectl -n argocd annotate ingress argocd-server \
  traefik.ingress.kubernetes.io/router.tls.options-
```

**Renewal.** The CA is valid to **2029-11-01**. It is a static, public trust anchor, not a
cert we own, so there is nothing to renew until Cloudflare rotates it — at which point replace
`authenticated_origin_pull_ca.pem` and let Argo CD sync.

## What should NOT be gated

- **`registry.kiitconsulting.com`** — docker/kubelet can't do interactive SSO, and
  Cloudflare's free proxy caps uploads at **100 MB** (breaks image pushes). Keep it
  **grey**.
- Anything consumed by machines (APIs, webhooks, `bayes-ingest` if scraped) — use a
  **service token** or **bypass policy** for those paths instead of a login.
- **WebSocket paths** — see the bypass recipe above; a login redirect is unfollowable by a
  socket.

## Caveats

- **Origin-IP bypass — closed for orange hosts on 2026-10-01**, see the section above. The
  old note here said Authenticated Origin Pulls was blocked "because grey hosts (echo,
  podinfo, registry, bayes-ingest) still need direct access". **That reasoning was wrong**:
  AOP is a property of the *Cloudflare→origin* leg, and a grey host never traverses
  Cloudflare at all, so zone-level AOP cannot affect it. The real scoping is done at Traefik,
  per router, by the `router.tls.options` annotation — grey hosts simply do not carry it.
  Verified after arming: `git` and `registry` unchanged (200 / 401 on `/v2/`), `argo` and
  `grafana-k8s` refusing direct TLS.
- **Don't reach for an IP allowlist on this cluster.** Two independent reasons, both measured:
  (1) an allowlist on `CF-Connecting-IP` is a header anyone can set while the origin is
  directly reachable; (2) there is no usable IP to allowlist in the first place — k3s
  ServiceLB SNATs every inbound packet, so Traefik sees `10.42.0.1` as the peer **and**
  `X-Forwarded-For: 10.42.0.1`, identically for a Cloudflare request and a direct one. Fixing
  that would mean `externalTrafficPolicy: Local` on the Traefik Service (host-level, in
  `ai-hetzner`, not this repo). A client *certificate* sidesteps the whole question because it
  is a property of the connection that SNAT cannot launder.
- **Keep gated hosts orange.** Flipping one back to grey silently removes the SSO
  gate.
- Zone SSL mode is **Full (strict)** — the edge validates the origin's real LE
  cert. Grey hosts bypass Cloudflare, so the mode does not affect them.
