#!/usr/bin/env bash
# Post-import configuration: themes, CSP, Turnstile login flow.
#
# Prerequisite: Keycloak is up and realm CyberVem was imported.
# Users are NOT created here — add them manually in Admin Console.
#
# Usage (host, after unified compose is up):
#   cp .env.example .env && $EDITOR .env
#   ./scripts/post-import.sh
#
# Or via root compose bootstrap profile (recommended):
#   docker compose \
#     --env-file ../.env.prod --env-file ../gateway/.env \
#     --env-file ../server/.env --env-file ../keycloak/.env \
#     -f ../docker-compose.prod.yml --profile bootstrap up keycloak-post-import

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

keycloak_container_ready() {
  docker exec "$KEYCLOAK_CONTAINER" bash -lc \
    'exec 3<>/dev/tcp/127.0.0.1/9000 && echo -e "GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 && grep -q "200 OK" <&3' \
    2>/dev/null
}

wait_for_keycloak() {
  local attempts=60
  local keycloak_url="${KEYCLOAK_URL:-http://127.0.0.1:8080}"
  for ((i = 1; i <= attempts; i++)); do
    if docker ps --format '{{.Names}}' | grep -qx "$KEYCLOAK_CONTAINER"; then
      if keycloak_container_ready; then
        return 0
      fi
    elif curl -fsS "${keycloak_url}/realms/${KEYCLOAK_REALM}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Keycloak did not become ready in time." >&2
  exit 1
}

echo "Waiting for Keycloak..."
wait_for_keycloak

echo "Ensuring standard client scopes (basic/sub/profile/email)..."
"${ROOT}/scripts/fix-client-scopes.sh"

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
