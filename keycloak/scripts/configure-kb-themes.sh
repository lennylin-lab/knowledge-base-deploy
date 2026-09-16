#!/usr/bin/env bash
# Set kb custom theme (login + admin favicon) on Keycloak realms.
#
# Usage:
#   ./scripts/configure-kb-themes.sh              # CyberVem + master
#   ./scripts/configure-kb-themes.sh CyberVem     # one realm

set -euo pipefail

REALMS=("$@")
if [[ ${#REALMS[@]} -eq 0 ]]; then
  REALMS=(CyberVem master)
fi

KEYCLOAK_URL="${KEYCLOAK_URL:-http://127.0.0.1:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD}"
KEYCLOAK_CONTAINER="${KEYCLOAK_CONTAINER:-knowledge-base-keycloak-prod}"

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

for realm in "${REALMS[@]}"; do
  kcadm update "realms/${realm}" -r master -s loginTheme=kb -s adminTheme=kb
  echo "Set loginTheme=kb and adminTheme=kb on realm '${realm}'."
done
