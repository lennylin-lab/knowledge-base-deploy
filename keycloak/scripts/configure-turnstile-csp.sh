#!/usr/bin/env bash
# Allow Cloudflare Turnstile on Keycloak login pages (realm-level CSP).
#
# Keycloak 26 ignores KC_SPI_CONTENT_SECURITY_POLICY_* env vars.
#
# Usage:
#   ./scripts/configure-turnstile-csp.sh
#   ./scripts/configure-turnstile-csp.sh CyberVem

set -euo pipefail

REALM="${1:-${KEYCLOAK_REALM:-CyberVem}}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://127.0.0.1:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"
KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-knowledge-base-keycloak-prod}"

CSP="frame-src 'self' https://challenges.cloudflare.com; frame-ancestors 'self'; object-src 'none'; script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com;"

kcadm() {
  if docker ps --format '{{.Names}}' | grep -qx "$KEYCLOAK_CONTAINER"; then
    docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh "$@"
  else
    "${KCADM:-kcadm.sh}" "$@"
  fi
}

if docker ps --format '{{.Names}}' | grep -qx "$KEYCLOAK_CONTAINER"; then
  kcadm config credentials \
    --server http://localhost:8080 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
else
  kcadm config credentials \
    --server "$KEYCLOAK_URL" --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
fi

kcadm update "realms/${REALM}" -s "browserSecurityHeaders.contentSecurityPolicy=${CSP}"

echo "Updated Content-Security-Policy for realm '${REALM}'."
