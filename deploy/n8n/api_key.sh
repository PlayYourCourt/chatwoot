#!/usr/bin/env bash
# Creates (or re-keys) a bearer token for the sequence engine's Enroll / Exit / Events webhooks and prints it once.
# Only the SHA-256 digest is stored (seq_api_keys); paste the printed token into the caller (Klaviyo webhook header
# `Authorization: Bearer <token>`) and a password manager. Running it again for the same name replaces the token.
#
#   deploy/n8n/api_key.sh klaviyo "postgres://doadmin:…@host:25060/seq?sslmode=require"
#
# Locally (Postgres runs in compose, no published port):
#   PSQL="docker compose -f deploy/docker-compose.local.yml exec -T postgres psql -U postgres -d seq" deploy/n8n/api_key.sh klaviyo
set -euo pipefail

NAME=${1:?key name, e.g. klaviyo}
PSQL=${PSQL:-"psql ${2:?seq database url}"}
TOKEN=$(openssl rand -hex 32)
DIGEST=$(printf '%s' "$TOKEN" | openssl dgst -sha256 | awk '{print $NF}')

$PSQL -v ON_ERROR_STOP=1 -qX <<SQL
INSERT INTO seq_api_keys (name, token_digest)
VALUES ('$NAME', '$DIGEST')
ON CONFLICT (name) DO UPDATE SET token_digest = EXCLUDED.token_digest, revoked_at = NULL, created_at = now();
SQL

echo "API key '$NAME' saved. Token (shown once):"
echo "$TOKEN"
