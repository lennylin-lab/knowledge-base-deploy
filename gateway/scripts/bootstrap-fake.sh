#!/usr/bin/env bash
# Minimal Gateway bootstrap for a fresh kb-deploy stack (seed catalog only).
#
# - Sets subject_default default chat + embedding models to gateway-echo
# - Mints one API key for subject_default
# - Prints server/.env lines to paste
#
# Prerequisites: gateway is up (/readyz 200), GATEWAY_ADMIN_TOKEN in gateway/.env
#
# Usage (from repo root):
#   ./gateway/scripts/bootstrap-fake.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATEWAY_ENV="${ROOT}/gateway/.env"

if [[ -f "${GATEWAY_ENV}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${GATEWAY_ENV}"
  set +a
fi

GATEWAY_PUBLIC_URL="${GATEWAY_PUBLIC_URL:-http://127.0.0.1:${GATEWAY_HOST_PORT:-8091}}"
GATEWAY_ADMIN_URL="${GATEWAY_ADMIN_URL:-http://127.0.0.1:${GATEWAY_ADMIN_HOST_PORT:-8092}}"

SUBJECT="${GATEWAY_SERVER_SUBJECT:-subject_default}"
CHAT_MODEL="${GATEWAY_FAKE_CHAT_MODEL:-gateway-echo}"
EMBED_MODEL="${GATEWAY_FAKE_EMBED_MODEL:-gateway-echo}"
ADMIN_TOKEN="${GATEWAY_ADMIN_TOKEN:?set GATEWAY_ADMIN_TOKEN in gateway/.env}"

auth=(-H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json")

wait_ready() {
  local attempts=60
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "${GATEWAY_PUBLIC_URL}/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Gateway /readyz did not return 200 in time." >&2
  exit 1
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
field, raw = sys.argv[1], sys.argv[2]
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)
value = data.get(field)
if value is None:
    sys.exit(1)
print(value)
PY
}

echo "Waiting for Gateway..."
wait_ready

echo "Setting default chat model (${CHAT_MODEL}) for subject ${SUBJECT}..."
curl -fsS -X POST "${GATEWAY_ADMIN_URL}/admin/policies/${SUBJECT}/default-model" \
  "${auth[@]}" -d "{\"model\":\"${CHAT_MODEL}\",\"kind\":\"chat\"}" >/dev/null

echo "Setting default embedding model (${EMBED_MODEL}) for subject ${SUBJECT}..."
curl -fsS -X POST "${GATEWAY_ADMIN_URL}/admin/policies/${SUBJECT}/default-model" \
  "${auth[@]}" -d "{\"model\":\"${EMBED_MODEL}\",\"kind\":\"embedding\"}" >/dev/null

echo "Minting API key for subject ${SUBJECT}..."
create_resp="$(curl -fsS -X POST "${GATEWAY_ADMIN_URL}/admin/keys" \
  "${auth[@]}" -d "{\"subject\":\"${SUBJECT}\",\"expires_in_hours\":8760}")"
key_id="$(json_field key_id "${create_resp}")"
api_key="$(json_field key "${create_resp}")"

cat <<EOF

Done.

Paste into server/.env (then start server):

  KB_CHAT_API_KEY=${api_key}
  KB_EMBEDDING_API_KEY=${api_key}
  KB_CHAT_MODEL=${CHAT_MODEL}
  KB_EMBEDDING_MODEL=${EMBED_MODEL}
  KB_EMBEDDING_DIM=256

Start server:

  docker compose --env-file .env.prod --env-file gateway/.env \\
    --env-file server/.env --env-file keycloak/.env \\
    -f docker-compose.prod.yml --profile app up -d server

Minted key id: ${key_id} (plaintext shown once above)
EOF
