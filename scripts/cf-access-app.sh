#!/usr/bin/env bash
# Put Cloudflare Access (SSO) in front of a hostname served by this cluster.
#
#   scripts/cf-access-app.sh "Grafana (k8s)" grafana-k8s.kiitconsulting.com ivanov.konstantin.89@gmail.com [more@emails ...]
#
# Creates a self-hosted Access application + an allow-policy for the given
# email(s), then flips the DNS record to orange (proxied) so Access enforces.
# Requires: the app already has a public HTTPS Ingress (cert via DNS-01), and a
# Cloudflare token with Account:Access:Apps:Edit + Zone:DNS:Edit
# (op://ai-skills/cloudflare-api/api_token). Idempotent-ish: re-running creates a
# second app for the same domain, so delete the old one first if re-provisioning.
set -euo pipefail

NAME="${1:?app name}"; DOMAIN="${2:?fqdn}"; shift 2
EMAILS=("$@"); [ "${#EMAILS[@]}" -gt 0 ] || { echo "give at least one allowed email"; exit 1; }

CF="$(op read 'op://ai-skills/cloudflare-api/api_token')"
ACCT=e51f67e175a1477e8cc239f9247f3250
ZONE=80f066660ab010032e73f8453afd5737
export CF ACCT ZONE NAME DOMAIN
printf '%s\n' "${EMAILS[@]}" | python3 - "$@" <<'PY'
import json,os,sys,urllib.request,urllib.error
CF=os.environ["CF"]; ACCT=os.environ["ACCT"]; ZONE=os.environ["ZONE"]
NAME=os.environ["NAME"]; DOMAIN=os.environ["DOMAIN"]; emails=sys.argv[1:]
def cf(method,path,body=None):
    req=urllib.request.Request("https://api.cloudflare.com/client/v4"+path,method=method,
        headers={"Authorization":f"Bearer {CF}","Content-Type":"application/json"},
        data=json.dumps(body).encode() if body else None)
    try: return json.load(urllib.request.urlopen(req,timeout=30))
    except urllib.error.HTTPError as e: return json.load(e)

app=cf("POST",f"/accounts/{ACCT}/access/apps",{
    "name":NAME,"type":"self_hosted","domain":DOMAIN,
    "session_duration":"24h","app_launcher_visible":True,"auto_redirect_to_identity":False})
assert app.get("success"),app.get("errors")
aid=app["result"]["id"]; print("app:",aid)
pol=cf("POST",f"/accounts/{ACCT}/access/apps/{aid}/policies",{
    "name":"Allow","decision":"allow","include":[{"email":{"email":e}} for e in emails]})
assert pol.get("success"),pol.get("errors"); print("policy: ok for",emails)

# flip DNS -> orange
recs=cf("GET",f"/zones/{ZONE}/dns_records?name={DOMAIN}")["result"]
assert recs, f"no DNS record for {DOMAIN} — create it first"
rid=recs[0]["id"]
cf("PATCH",f"/zones/{ZONE}/dns_records/{rid}",{"proxied":True})
print("proxied:",DOMAIN,"-> orange")
PY
echo "Done. Visit https://$DOMAIN — it should redirect to the Cloudflare Access login."
