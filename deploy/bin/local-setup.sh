#!/usr/bin/env bash
# One-time local bootstrap: creates deploy/.env.local, builds the image, prepares the database.
set -euo pipefail
cd "$(dirname "$0")/../.."

COMPOSE="docker compose -f deploy/docker-compose.local.yml"

if [ ! -f deploy/.env.local ]; then
  cp deploy/.env.local.example deploy/.env.local
  secret=$(openssl rand -hex 64)
  sed -i "s/^SECRET_KEY_BASE=.*/SECRET_KEY_BASE=${secret}/" deploy/.env.local
  echo "Created deploy/.env.local"
fi

$COMPOSE build
$COMPOSE up -d postgres redis
$COMPOSE run --rm rails bundle exec rails db:chatwoot_prepare
$COMPOSE up -d

echo "Chatwoot: http://localhost:3000   Mailhog: http://localhost:8025"
