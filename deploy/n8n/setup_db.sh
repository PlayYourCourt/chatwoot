#!/usr/bin/env bash
# Creates the databases and roles the n8n sequence engine needs and loads the seq schema. Idempotent.
#
#   N8N_DB_PASSWORD=… SEQ_ENGINE_PASSWORD=… CHATWOOT_READONLY_PASSWORD=… \
#     deploy/n8n/setup_db.sh "postgres://doadmin:…@host:25060/defaultdb?sslmode=require"
#
# Locally (Postgres runs in compose, no published port) point PSQL at the container instead:
#   PSQL="docker compose -f deploy/docker-compose.local.yml exec -T postgres psql -U postgres" deploy/n8n/setup_db.sh
#
# Creates: role n8n + database n8n (n8n's own tables), role seq_engine + database seq (engine state, no DELETE
# on logs), role chatwoot_readonly with SELECT on the Chatwoot tables the Gate reads (CHATWOOT_DB, default
# chatwoot_production). Passwords are only set when the role is first created.
set -euo pipefail
cd "$(dirname "$0")/../.."

CHATWOOT_DB=${CHATWOOT_DB:-chatwoot_production}
PSQL=${PSQL:-"psql ${1:?admin postgres url}"}
: "${N8N_DB_PASSWORD:?}" "${SEQ_ENGINE_PASSWORD:?}" "${CHATWOOT_READONLY_PASSWORD:?}"

run() { $PSQL -v ON_ERROR_STOP=1 -qX "$@"; }

run <<SQL
SELECT format('CREATE ROLE n8n LOGIN PASSWORD %L', '$N8N_DB_PASSWORD')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n') \gexec
SELECT format('CREATE ROLE seq_engine LOGIN PASSWORD %L', '$SEQ_ENGINE_PASSWORD')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'seq_engine') \gexec
SELECT format('CREATE ROLE chatwoot_readonly LOGIN PASSWORD %L', '$CHATWOOT_READONLY_PASSWORD')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'chatwoot_readonly') \gexec
SELECT 'CREATE DATABASE n8n' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n') \gexec
SELECT 'CREATE DATABASE seq' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'seq') \gexec
GRANT CONNECT, CREATE, TEMP ON DATABASE n8n TO n8n;
GRANT CONNECT ON DATABASE seq TO seq_engine;
GRANT CONNECT ON DATABASE "$CHATWOOT_DB" TO chatwoot_readonly;
SQL

run -d n8n -c 'GRANT ALL ON SCHEMA public TO n8n'   # n8n creates its own tables

run -d seq < deploy/n8n/sql/seq_schema.sql
run -d "$CHATWOOT_DB" < deploy/n8n/sql/chatwoot_readonly.sql
echo "n8n, seq and chatwoot_readonly are ready"
