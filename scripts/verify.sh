#!/usr/bin/env bash
# Health check for the lab. Run this BEFORE debugging any federation config.
#
# Most "SAML is broken" sessions are actually "a container is not running" or
# "the security group does not let my browser in". Rule those out first.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f .env ] && set -a && . ./.env && set +a

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo
echo "PingFederate lab — verification"
echo "HOST_IP = ${HOST_IP:-<unset>}"
echo

# --- 1. env sanity -----------------------------------------------------------
echo "1. Environment"
[ -f .env ] || bad ".env missing — copy .env.example to .env"
if [ -z "${HOST_IP:-}" ]; then
  bad "HOST_IP unset"
elif [[ "$HOST_IP" =~ ^(localhost|127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|192\.168\.) ]]; then
  bad "HOST_IP=$HOST_IP is local/private — the browser cannot reach it. Use the Elastic IP."
else
  ok "HOST_IP looks routable ($HOST_IP)"
fi
[ -n "${PING_IDENTITY_DEVOPS_KEY:-}" ] && ok "DevOps key set" || bad "PING_IDENTITY_DEVOPS_KEY unset"
echo

# --- 2. containers -----------------------------------------------------------
echo "2. Containers"
for c in pf keycloak saml-app grafana; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    # {{if .State.Health}} guards containers with no HEALTHCHECK at all —
    # without it this template's behavior on a missing Health field is
    # inconsistent across Docker versions (empty string on some, a template
    # error on others), which is exactly the garbled output that motivated
    # this fix.
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$c" 2>/dev/null)
    [ -z "$status" ] && status="unknown"
    if [ "$status" = "healthy" ] || [ "$status" = "no-healthcheck" ]; then ok "$c running ($status)"
    else bad "$c running but health=$status"; fi
  else
    bad "$c not running"
  fi
done
echo

# --- 3. endpoints ------------------------------------------------------------
echo "3. Endpoints"
check() { # name url
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$2" 2>/dev/null)
  if [ "$code" != "000" ] && [ -n "$code" ]; then ok "$1 -> HTTP $code"
  else bad "$1 unreachable ($2)"; fi
}

# PF's admin console and runtime are checked via loopback, not HOST_IP.
# Self-curling your own public IP round-trips through the IGW and re-enters
# as if from the internet, so the security group evaluates it like any other
# inbound connection — and correctly REJECTS it, because 9999/9031 are locked
# to your laptop's /32, not this host. That is the security group working as
# intended, not a fault. Loopback bypasses the security group entirely and
# answers the question these checks actually care about: is PF up and
# listening. It says nothing about whether YOUR LAPTOP can reach it.
echo "   (PF checked via loopback — SG restricts 9999/9031 to your laptop, not this host)"
check "PF admin console (local)"  "https://127.0.0.1:9999/pingfederate/app"
check "PF runtime engine (local)" "https://127.0.0.1:9031/pf/heartbeat.ping"

# Keycloak/SAML SP/Grafana are open to 0.0.0.0/0, so self-hairpin via HOST_IP
# genuinely exercises the same path a browser would use. These checks stay
# public-IP-based on purpose.
check "Keycloak realm"    "http://${HOST_IP}:8080/realms/byoi-test"
check "SAML SP health"    "http://${HOST_IP}:5000/health"
check "SAML SP metadata"  "http://${HOST_IP}:5000/metadata"
check "Grafana"           "http://${HOST_IP}:3000/login"
echo
echo "   PF's real test is from your LAPTOP, since that's the only place the"
echo "   security group actually allows in. Confirm separately:"
echo "     https://${HOST_IP}:9999/pingfederate/app"
echo "     https://${HOST_IP}:9031/pf/heartbeat.ping"
echo

# --- 4. phase readiness ------------------------------------------------------
echo "4. Phase readiness"
if [ -n "${IDP_ENTITY_ID:-}" ] && [ -n "${IDP_X509_CERT:-}" ]; then
  ok "SAML SP has IdP config (Phase 2 ready)"
else
  echo "  [ -- ] SAML SP has no IdP config yet — expected until Phase 2"
fi
if [ "${OIDC_ENABLED:-false}" = "true" ] && [ -n "${OIDC_CLIENT_ID:-}" ]; then
  ok "Grafana OIDC enabled (Phase 5 ready)"
else
  echo "  [ -- ] Grafana OIDC not enabled yet — expected until Phase 5"
fi
echo

echo "-------------------------------------------"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "Lab is up." || echo "Fix the failures above before touching PingFederate config."
echo
exit 0
