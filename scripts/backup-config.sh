#!/usr/bin/env bash
# Export PingFederate configuration via the Admin API.
#
# Two reasons to use this:
#   1. A bad experiment becomes recoverable instead of a rebuild.
#   2. It is your first contact with the Admin API, which Days 18-22 need.
#
# Usage: ./scripts/backup-config.sh [label]

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
[ -f .env ] && set -a && . ./.env && set +a

LABEL="${1:-manual}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="backups/${STAMP}-${LABEL}"
mkdir -p "$OUT"

API="https://${HOST_IP}:9999/pf-admin-api/v1"
AUTH="administrator:${PF_ADMIN_PASSWORD}"
HDR='X-XSRF-Header: PingFederate'

echo "Exporting PingFederate config -> $OUT"

fetch() { # endpoint filename
  echo -n "  $2 ... "
  if curl -sk -u "$AUTH" -H "$HDR" --max-time 20 "${API}$1" -o "${OUT}/$2" 2>/dev/null; then
    echo "ok ($(wc -c < "${OUT}/$2") bytes)"
  else
    echo "FAILED"
  fi
}

fetch "/idp/spConnections"            "idp-sp-connections.json"
fetch "/sp/idpConnections"            "sp-idp-connections.json"
fetch "/idp/adapters"                 "idp-adapters.json"
fetch "/authenticationPolicyContracts" "authn-policy-contracts.json"
fetch "/authenticationPolicies"       "authn-policies.json"
fetch "/oauth/clients"                "oauth-clients.json"
fetch "/oauth/accessTokenManagers"    "oauth-token-managers.json"
fetch "/oauth/openIdConnect/policies" "oidc-policies.json"
fetch "/serverSettings"               "server-settings.json"
fetch "/keyPairs/signing"             "signing-keys.json"

echo
echo "Saved to $OUT"
echo "Tip: diff two backups to see exactly what a console change altered."
