#!/usr/bin/env bash
# First-boot only: create isolated databases for gateway, server (pgvector), and keycloak.
# Passwords may contain single quotes; identifiers are double-quoted when needed.
set -euo pipefail

sql_escape_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_escape_ident() {
  printf '%s' "$1" | sed 's/"/""/g'
}

create_role_and_database() {
  local role=$1 password=$2 db=$3
  local role_q db_q pass_lit
  role_q="$(sql_escape_ident "$role")"
  db_q="$(sql_escape_ident "$db")"
  pass_lit="$(sql_escape_literal "$password")"

  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${role_q}') THEN
    EXECUTE format('CREATE USER %I WITH PASSWORD %L', '${role_q}', '${pass_lit}');
  END IF;
END
\$\$;
CREATE DATABASE "${db_q}" OWNER "${role_q}";
GRANT ALL PRIVILEGES ON DATABASE "${db_q}" TO "${role_q}";
EOSQL
}

create_role_and_database "${GATEWAY_DB_USER}" "${GATEWAY_DB_PASSWORD}" "${GATEWAY_DB_NAME}"
create_role_and_database "${KB_DB_USER}" "${KB_DB_PASSWORD}" "${KB_DB_NAME}"
create_role_and_database "${KEYCLOAK_DB_USER}" "${KEYCLOAK_DB_PASSWORD}" "${KEYCLOAK_DB_NAME}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${KB_DB_NAME}" <<-EOSQL
CREATE EXTENSION IF NOT EXISTS vector;
EOSQL
