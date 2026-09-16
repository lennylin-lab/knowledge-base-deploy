#!/usr/bin/env bash
# Idempotent theme + CSP setup via kcadm (compose one-shot or host with KEYCLOAK_URL).
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://127.0.0.1:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-CyberVem}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"

CSP="frame-src 'self' https://challenges.cloudflare.com; frame-ancestors 'self'; object-src 'none'; script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com;"

kcadm="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

"$kcadm" config credentials \
  --server "$KEYCLOAK_URL" --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

for realm in "$KEYCLOAK_REALM" master; do
  "$kcadm" update "realms/${realm}" -r master -s loginTheme=kb -s adminTheme=kb
  echo "Set loginTheme=kb and adminTheme=kb on realm '${realm}'."
done

"$kcadm" update "realms/${KEYCLOAK_REALM}" -s "browserSecurityHeaders.contentSecurityPolicy=${CSP}"
echo "Updated Content-Security-Policy for realm '${KEYCLOAK_REALM}'."
