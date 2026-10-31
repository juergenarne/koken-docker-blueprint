#!/usr/bin/env bash
#
# Updates the Docker setup of a running installation (on a server: as root):
#   1. this repository                 git pull (public repository, no key needed)
#   2. containers                      rebuilt/restarted only if the Docker setup changed
#
# Koken itself (the web root) and themes/plugins checked out with git are updated by
# the owner of the web root, without Docker: ./update-app.sh
# Photos, themes, plugins and configuration (storage/) and the database are never touched.
# Usage: ./update.sh
#
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else fail "Docker Compose is not installed."; fi

[ -w .git ] || fail "No write access to this repository – on a server run as root: sudo ./update.sh"

get_env() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }
set_env() {
    local tmp; tmp=$(mktemp)
    if grep -q "^$1=" .env; then
        awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' .env > "$tmp"
    else
        cat .env > "$tmp"; [ -n "$(tail -c 1 .env)" ] && echo >> "$tmp"; printf '%s=%s\n' "$1" "$2" >> "$tmp"
    fi
    cat "$tmp" > .env; rm -f "$tmp"
}

# docker-compose.yml mounts APACHE_HTDOCS as it is: a relative path needs a leading ./
# (older .env files: src/htdocs or ${APACHE_SRC}/htdocs)
HTDOCS=$(get_env APACHE_HTDOCS); HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(get_env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=./src/htdocs ;; esac
case "$HTDOCS" in /*|./*|../*) ;; *) HTDOCS="./$HTDOCS" ;; esac
[ "$(get_env APACHE_HTDOCS)" = "$HTDOCS" ] || set_env APACHE_HTDOCS "$HTDOCS"
# DB_PORT (database on 127.0.0.1 of the host): older .env files have none – pick a free one
if [ -z "$(get_env DB_PORT)" ]; then
    p=3307
    while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do p=$((p + 1)); done
    set_env DB_PORT "$p"
    say "Database port: 127.0.0.1:$p (DB_PORT in .env)"
fi
[ -f "$HTDOCS/index.php" ] || fail "No Koken in $HTDOCS (APACHE_HTDOCS in .env) – run ./setup.sh first."

say "Docker setup:"
before=$(git rev-parse HEAD)
git fetch -q
if ! git merge-base --is-ancestor HEAD '@{u}'; then
    # Local commits that change nothing (e.g. bookkeeping commits of migrate-server.sh)
    # are dropped; anything else is left for you to sort out.
    base=$(git merge-base HEAD '@{u}')
    git diff --quiet "$base" HEAD || fail "This repository has local commits with changes – merge or rebase them first (git log @{u}..HEAD)."
    git reset -q "$base"
fi
git merge --ff-only '@{u}'
docker_changed=$(git diff --name-only "$before" HEAD -- Dockerfile docker-compose.yml config docker | head -n 1)

if [ -n "$docker_changed" ]; then
    say "Docker setup changed – rebuilding the containers …"
    "${COMPOSE[@]}" up -d --build
else
    "${COMPOSE[@]}" up -d
fi

say "Done: Docker setup $(git rev-parse --short HEAD)"
if [ "$(id -u)" = 0 ]; then
    echo "Koken itself:  sudo -u www-data -H $PWD/update-app.sh $HTDOCS"
else
    echo "Koken itself:  ./update-app.sh"
fi
