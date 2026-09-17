#!/usr/bin/env bash
# First-boot only (docker-entrypoint-initdb.d): create gateway / kb / keycloak databases.
# NOT idempotent — runs once on an empty postgres-data volume; re-run manually will fail
# if roles/databases already exist.
#
# Passwords and identifiers are passed via psql -v; psql substitutes :'var' before SQL is
# sent, then format(%I/%L) quotes safely. Do not pre-escape in shell.
set -euo pipefail

create_role_and_database() {
  local role=$1 password=$2 db=$3
  psql -v ON_ERROR_STOP=1 \
    --username "${POSTGRES_USER}" \
    --dbname "${POSTGRES_DB}" \
    -v "role=${role}" \
    -v "pass=${password}" \
    -v "db=${db}" <<'EOSQL'
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') AS need_role \gset
\if :need_role
SELECT format('CREATE USER %I WITH PASSWORD %L', :'role', :'pass') \gexec
\endif
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role') \gexec
SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db', :'role') \gexec
EOSQL
}

create_role_and_database "${GATEWAY_DB_USER}" "${GATEWAY_DB_PASSWORD}" "${GATEWAY_DB_NAME}"
create_role_and_database "${KB_DB_USER}" "${KB_DB_PASSWORD}" "${KB_DB_NAME}"
create_role_and_database "${KEYCLOAK_DB_USER}" "${KEYCLOAK_DB_PASSWORD}" "${KEYCLOAK_DB_NAME}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${KB_DB_NAME}" <<-EOSQL
CREATE EXTENSION IF NOT EXISTS vector;
EOSQL
