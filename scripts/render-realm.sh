#!/usr/bin/env bash
# Substitute HOST_IP into the Keycloak realm file.
#
# The realm ships with placeholders because redirect URIs must contain the real
# EC2 address — Keycloak rejects a redirect that does not match exactly.
#
# Run this ONCE after setting HOST_IP in .env, BEFORE first `docker compose up`.
# Re-run it if HOST_IP ever changes (then delete the kc-data volume so the
# realm re-imports).

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
set -a && . ./.env && set +a

SRC="keycloak/realm-byoi-test.json"
[ -f "${SRC}.template" ] || cp "$SRC" "${SRC}.template"

sed "s|HOST_IP_PLACEHOLDER|${HOST_IP}|g" "${SRC}.template" > "$SRC"

echo "Rendered ${SRC} with HOST_IP=${HOST_IP}"
echo
echo "Still a placeholder on purpose: PF_SAML_ENTITY_ID_PLACEHOLDER"
echo "  Phase 4 only. Set PingFederate's SAML entity ID in Server Settings first,"
echo "  then replace that string and re-import the realm."
