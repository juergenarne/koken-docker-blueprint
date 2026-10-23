#!/usr/bin/env bash
#
# Sets up the Koken environment (PHP 8.5 + Apache + MariaDB in Docker):
#   1. creates .env from .env.example (random passwords + installer token)
#   2. builds and starts the containers
#   3. waits until the web server answers and prints the installer link
#
# Usage: ./setup.sh [-y] [-p PORT]
#   -y        non-interactive, accept defaults
#   -p PORT   host port for the website (default 8080)
#
set -euo pipefail
cd "$(dirname "$0")"

ASSUME_YES=false
PORT=""
while getopts "yp:h" opt; do
    case "$opt" in
        y) ASSUME_YES=true ;;
        p) PORT="$OPTARG" ;;
        *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    esac
done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- requirements --------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "Docker is not installed (https://docs.docker.com/get-docker/)."
docker info >/dev/null 2>&1 || fail "Docker is not running."
if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    fail "Docker Compose is not installed."
fi
command -v curl >/dev/null 2>&1 || fail "curl is required."

random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"; }

# set_env KEY VALUE – replace or append a line in .env (portable, no sed -i)
set_env() {
    local tmp
    tmp=$(mktemp)
    if grep -q "^$1=" .env; then
        awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' .env > "$tmp"
    else
        cat .env > "$tmp"
        printf '%s=%s\n' "$1" "$2" >> "$tmp"
    fi
    cat "$tmp" > .env
    rm -f "$tmp"
}

get_env() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }

# --- .env ------------------------------------------------------------------------
if [ ! -f .env ]; then
    say "Creating .env"
    cp .env.example .env
    chmod 600 .env
fi

if [ -n "$PORT" ]; then
    set_env APACHE_PORT "$PORT"
elif ! $ASSUME_YES && [ -t 0 ]; then
    current=$(get_env APACHE_PORT)
    read -r -p "Port for the website [${current:-8080}]: " answer
    [ -n "$answer" ] && set_env APACHE_PORT "$answer"
fi

[ -n "$(get_env MYSQL_PASSWORD)" ]      || set_env MYSQL_PASSWORD "$(random 24)"
[ -n "$(get_env MYSQL_ROOT_PASSWORD)" ] || set_env MYSQL_ROOT_PASSWORD "$(random 32)"
[ -n "$(get_env KOKEN_INSTALL_TOKEN)" ] || set_env KOKEN_INSTALL_TOKEN "$(random 32)"

PORT=$(get_env APACHE_PORT); PORT=${PORT:-8080}
TOKEN=$(get_env KOKEN_INSTALL_TOKEN)

# --- start -----------------------------------------------------------------------
say "Building and starting the containers (first run takes a few minutes) …"
"${COMPOSE[@]}" up -d --build

say "Waiting for the web server on port $PORT …"
for _ in $(seq 1 90); do
    if curl -fsS "http://localhost:$PORT/install/index.php?ping=1" 2>/dev/null | grep -q koken-installer-pong; then
        READY=true
        break
    fi
    sleep 2
done
[ "${READY:-false}" = true ] || fail "The web server did not answer. Check: ${COMPOSE[*]} logs web"

echo
HTDOCS=$(get_env APACHE_HTDOCS); case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; esac
if [ -f "$HTDOCS/storage/configuration/database.php" ]; then
    say "Koken is running: http://localhost:$PORT/   (admin: http://localhost:$PORT/admin/)"
else
    say "Done. Open the installer to finish the setup in your browser:"
    echo
    echo "    http://localhost:$PORT/install/?token=$TOKEN"
    echo
    echo "(On a server, replace localhost with its domain name.)"
fi
