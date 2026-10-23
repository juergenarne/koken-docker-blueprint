#!/usr/bin/env bash
#
# Updates a running installation:
#   1. this repository (Docker setup)       git pull
#   2. Koken itself (src/htdocs)            git pull
#   3. containers                           rebuilt/restarted only if the Docker setup changed
#   4. Koken's API/site cache               cleared, so code changes show up immediately
#
# Photos, themes, plugins and configuration (src/htdocs/storage) and the database are
# never touched. Usage: ./update.sh
#
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else fail "Docker Compose is not installed."; fi

get_env() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }
HTDOCS=$(get_env APACHE_HTDOCS); case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; esac
APP_NAME=$(get_env APP_NAME); APP_NAME=${APP_NAME:-koken}
[ -d "$HTDOCS/.git" ] || fail "$HTDOCS is not a git checkout (old setup?) – see migrate-server.sh."

say "Docker setup:"
before=$(git rev-parse HEAD)
git pull --ff-only
docker_changed=$(git diff --name-only "$before" HEAD -- Dockerfile docker-compose.yml config docker | head -n 1)

say "Koken ($HTDOCS):"
git -C "$HTDOCS" pull --ff-only

if [ -n "$docker_changed" ]; then
    say "Docker setup changed – rebuilding the containers …"
    "${COMPOSE[@]}" up -d --build
else
    "${COMPOSE[@]}" up -d
fi

say "Clearing Koken's API and page cache …"
docker exec "$APP_NAME-apache" sh -c 'rm -rf /var/www/html/storage/cache/api/* /var/www/html/storage/cache/site/* /var/www/html/storage/cache/plugins/*' || true

say "Done: Docker setup $(git rev-parse --short HEAD), Koken $(git -C "$HTDOCS" rev-parse --short HEAD)"
