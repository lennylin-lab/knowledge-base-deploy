#!/usr/bin/env bash
# Ensure CyberVem has standard OIDC client scopes and kb-web assignments.
#
# Fresh imports: cybervem-realm.json now ships full clientScopes (incl. basic/sub).
# Existing broken imports (only kb-api-audience): this script creates missing scopes
# from keycloak/client-scopes-standard.json and re-attaches them to clients.
#
# Idempotent — safe to run on every bootstrap.
set -euo pipefail

KEYCLOAK_REALM="${KEYCLOAK_REALM:-CyberVem}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://127.0.0.1:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STANDARD_SCOPES_FILE="${STANDARD_SCOPES_FILE:-${SCRIPT_DIR}/../client-scopes-standard.json}"

kcadm="${KCADM:-/opt/keycloak/bin/kcadm.sh}"

KB_WEB_DEFAULT_SCOPES=(
  web-origins acr profile roles basic kb-api-audience email
)
KB_WEB_OPTIONAL_SCOPES=(
  address phone offline_access microprofile-jwt
)
KB_API_DEFAULT_SCOPES=(
  web-origins acr profile roles basic email
)
KB_API_OPTIONAL_SCOPES=(
  address phone offline_access microprofile-jwt
)

scope_id() {
  local name=$1
  "$kcadm" get client-scopes -r "$KEYCLOAK_REALM" -q "name=${name}" \
    --fields id --format csv --noquotes 2>/dev/null | head -1
}

client_id() {
  local clientId=$1
  "$kcadm" get clients -r "$KEYCLOAK_REALM" -q "clientId=${clientId}" \
    --fields id --format csv --noquotes 2>/dev/null | head -1
}

ensure_standard_scopes() {
  if [[ ! -f "${STANDARD_SCOPES_FILE}" ]]; then
    echo "error: missing ${STANDARD_SCOPES_FILE}" >&2
    exit 1
  fi

  python3 - "${STANDARD_SCOPES_FILE}" <<'PY'
import json, sys, tempfile, os, subprocess
path = sys.argv[1]
scopes = json.load(open(path))
kcadm = os.environ.get("KCADM", "/opt/keycloak/bin/kcadm.sh")
realm = os.environ["KEYCLOAK_REALM"]
for scope in scopes:
    name = scope["name"]
    existing = subprocess.run(
        [kcadm, "get", "client-scopes", "-r", realm, "-q", f"name={name}", "--fields", "id"],
        capture_output=True, text=True, check=True,
    )
    if json.loads(existing.stdout or "[]"):
        print(f"scope exists: {name}")
        continue
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(scope, f)
        tmp = f.name
    try:
        subprocess.run([kcadm, "create", "client-scopes", "-r", realm, "-f", tmp], check=True)
        print(f"created scope: {name}")
    finally:
        os.unlink(tmp)
PY
}

assign_scopes() {
  local cid=$1 kind=$2
  shift 2
  local -a names=("$@")
  local scope cid_path scope_id_val

  if [[ -z "${cid}" ]]; then
    echo "warning: client not found for ${kind} assignment" >&2
    return 0
  fi

  if [[ "${kind}" == "default" ]]; then
    cid_path="default-client-scopes"
  else
    cid_path="optional-client-scopes"
  fi

  for scope in "${names[@]}"; do
    scope_id_val="$(scope_id "${scope}")"
    if [[ -z "${scope_id_val}" ]]; then
      echo "warning: scope '${scope}' missing — skip ${kind} assign for client ${cid}" >&2
      continue
    fi
    if "$kcadm" get "clients/${cid}/${cid_path}" -r "$KEYCLOAK_REALM" --fields name 2>/dev/null \
      | python3 -c "import json,sys; names={x.get('name') for x in json.load(sys.stdin)}; sys.exit(0 if '${scope}' in names else 1)"; then
      continue
    fi
    "$kcadm" update "clients/${cid}/${cid_path}/${scope_id_val}" -r "$KEYCLOAK_REALM" -n "$KEYCLOAK_REALM"
    echo "assigned ${kind} scope '${scope}' to client ${cid}"
  done
}

"$kcadm" config credentials \
  --server "$KEYCLOAK_URL" --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

export KEYCLOAK_REALM KCADM
ensure_standard_scopes

web_id="$(client_id kb-web)"
api_id="$(client_id kb-api)"

assign_scopes "${web_id}" default "${KB_WEB_DEFAULT_SCOPES[@]}"
assign_scopes "${web_id}" optional "${KB_WEB_OPTIONAL_SCOPES[@]}"
assign_scopes "${api_id}" default "${KB_API_DEFAULT_SCOPES[@]}"
assign_scopes "${api_id}" optional "${KB_API_OPTIONAL_SCOPES[@]}"

echo "Client scope repair complete for realm '${KEYCLOAK_REALM}'."
