#!/usr/bin/env bash
# One-time Droplet bootstrap (Ubuntu). Run as root from the cloned repo:
#   deploy/bin/droplet-setup.sh
# Prerequisites: deploy/.env.do filled in, DNS A record for FRONTEND_HOST pointing here,
# and a GHCR read token exported as GHCR_USER / GHCR_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

[ -f deploy/.env.do ] || { echo "deploy/.env.do is missing (copy deploy/.env.do.example)"; exit 1; }

echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

COMPOSE="docker compose -f deploy/docker-compose.do.yml"
$COMPOSE pull
$COMPOSE up -d redis
$COMPOSE run --rm rails bundle exec rails db:chatwoot_prepare
$COMPOSE up -d

echo "Done. Open https://${FRONTEND_HOST:-your-domain} to run the one-time onboarding and create the first admin account."
