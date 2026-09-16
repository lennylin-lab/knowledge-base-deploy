#!/usr/bin/env bash
# Post-import configuration: themes, CSP, Turnstile login flow.
#
# Prerequisite: Keycloak is up and realm CyberVem was imported.
# Users are NOT created here — add them manually in Admin Console.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   # start Keycloak (image from KEYCLOAK_IMAGE), import import/cybervem-realm.json
#   ./scripts/post-import.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

KEYCLOAK_REALM="${KEYCLOAK_REALM:-CyberVem}"
KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-knowledge-base-keycloak-prod}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD in .env}"
TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:?set TURNSTILE_SITE_KEY in .env}"
TURNSTILE_SECRET_KEY="${TURNSTILE_SECRET_KEY:?set TURNSTILE_SECRET_KEY in .env}"

wait_for_keycloak() {
  local attempts=60
  for ((i = 1; i <= attempts; i++)); do
    if docker ps --format '{{.Names}}' | grep -qx "$KEYCLOAK_CONTAINER"; then
      if docker exec "$KEYCLOAK_CONTAINER" bash -lc 'exec 3<>/dev/tcp/127.0.0.1/8080' 2>/dev/null; then
        return 0
      fi
    elif curl -fsS "${KEYCLOAK_URL:-http://127.0.0.1:8080}/health/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Keycloak did not become ready in time." >&2
  exit 1
}

echo "Waiting for Keycloak..."
wait_for_keycloak

echo "Applying kb themes..."
./scripts/configure-kb-themes.sh "$KEYCLOAK_REALM" master

echo "Applying Turnstile CSP..."
./scripts/configure-turnstile-csp.sh "$KEYCLOAK_REALM"

echo "Configuring Turnstile single-page browser flow..."
python3 ./scripts/configure-turnstile-login.py

cat <<EOF

Done.

Next (manual):
  1. Admin Console → realm CyberVem → Users → create users
  2. Link each user's OIDC sub in knowledge-base-server Postgres (see server docs)
  3. Point reverse proxy auth.cybervem.com → keycloak:8080 with TLS + X-Forwarded-*

OIDC issuer for server / Flutter:
  https://auth.cybervem.com/realms/CyberVem

EOF
