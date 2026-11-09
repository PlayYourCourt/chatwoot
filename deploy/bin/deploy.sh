#!/usr/bin/env bash
# Redeploy after a new image is published: pull, migrate, restart.
#   deploy/bin/deploy.sh                                   # redeploy the pinned (or latest) image
#   deploy/bin/deploy.sh ghcr.io/playyourcourt/chatwoot:abc1234   # pin and deploy a specific build
# The image is pinned in deploy/.env (Compose interpolation file, git-ignored) so later `up` calls
# keep using the same build until the next deploy.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ $# -ge 1 ]; then
  printf 'CHATWOOT_IMAGE=%s\n' "$1" > deploy/.env
fi

COMPOSE="docker compose -f deploy/docker-compose.do.yml"
$COMPOSE pull rails
$COMPOSE run --rm rails bundle exec rails db:migrate
$COMPOSE up -d --remove-orphans
docker image prune -f >/dev/null
$COMPOSE ps
