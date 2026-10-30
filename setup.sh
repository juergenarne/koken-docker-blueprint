#!/usr/bin/env bash
#
# Sets up the Koken environment (PHP 8.5 + Apache + MariaDB in Docker):
#   1. creates .env from .env.dist (random passwords + installer token)
#   2. clones Koken (KOKEN_REPO) into the web root (APACHE_HTDOCS)
#   3. builds and starts the containers
#   4. waits until the web server answers and prints the installer link
#
# On a server it runs as root (sudo ./setup.sh): root owns this directory and Docker,
# www-data owns the web root outside of it (e.g. /var/www/htdocs/<domain>) and the
# deploy keys. Koken is therefore cloned as www-data; root needs no key.
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
        *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    cp .env.dist .env
fi
chmod 600 .env    # passwords: only for the owner of this directory (root on a server)

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

[ -n "$(get_env KOKEN_REPO)" ]   || set_env KOKEN_REPO "$(grep -E '^KOKEN_REPO=' .env.dist | cut -d= -f2-)"
[ -n "$(get_env KOKEN_BRANCH)" ] || set_env KOKEN_BRANCH master

PORT=$(get_env APACHE_PORT); PORT=${PORT:-8080}
TOKEN=$(get_env KOKEN_INSTALL_TOKEN)
# docker-compose.yml mounts APACHE_HTDOCS as it is: a relative path needs a leading ./
# (older .env files: src/htdocs or ${APACHE_SRC}/htdocs)
HTDOCS=$(get_env APACHE_HTDOCS); HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(get_env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=./src/htdocs ;; esac
case "$HTDOCS" in /*|./*|../*) ;; *) HTDOCS="./$HTDOCS" ;; esac
[ "$(get_env APACHE_HTDOCS)" = "$HTDOCS" ] || set_env APACHE_HTDOCS "$HTDOCS"

# --- server: root / www-data -----------------------------------------------------------
AS_ROOT=false
if [ "$(id -u)" = 0 ]; then
    AS_ROOT=true
    id www-data >/dev/null 2>&1 || fail "User www-data does not exist."
    command -v sudo >/dev/null 2>&1 || fail "sudo is required (to run git as www-data)."
    case "$HTDOCS" in
        /*) ;;
        *) fail "Running as root: APACHE_HTDOCS in .env must be the absolute path of the web root outside this directory, e.g. /var/www/htdocs/<domain> (see INSTALL.md)." ;;
    esac
fi
# web CMD… – run CMD as the owner of the web root (www-data on a server)
# (from /, as www-data may not enter this directory)
web() { if $AS_ROOT; then (cd / && sudo -u www-data -H "$@"); else "$@"; fi; }

# --- Koken code ------------------------------------------------------------------
# The web root is its own git repository (KOKEN_REPO). It is cloned on the first
# run; later updates: ./update-app.sh (by the owner of the web root)
if [ ! -f "$HTDOCS/index.php" ]; then
    REPO=$(get_env KOKEN_REPO); BRANCH=$(get_env KOKEN_BRANCH)
    [ -n "$REPO" ] || fail "KOKEN_REPO is not set in .env."
    command -v git >/dev/null 2>&1 || fail "git is required."
    say "Cloning Koken ($REPO, branch $BRANCH) into $HTDOCS$($AS_ROOT && echo ' as www-data' || true) …"
    if $AS_ROOT && [ ! -d "$HTDOCS" ]; then
        install -d -o www-data -g www-data "$HTDOCS"
    fi
    if [ -d "$HTDOCS" ] && [ -n "$(ls -A "$HTDOCS")" ]; then
        # Directory exists (e.g. only storage/): check out the code next to it.
        # Untracked files such as storage/ are never touched by git.
        web git -C "$HTDOCS" init -q -b "$BRANCH"
        web git -C "$HTDOCS" remote add origin "$REPO"
        web git -C "$HTDOCS" fetch -q origin "$BRANCH" || fail "Cannot fetch $REPO – deploy key? (INSTALL.md, step 1)"
        web git -C "$HTDOCS" checkout -q -B "$BRANCH" "origin/$BRANCH"
    else
        $AS_ROOT || mkdir -p "$(dirname "$HTDOCS")"
        web git clone -q --branch "$BRANCH" "$REPO" "$HTDOCS" || fail "Cannot clone $REPO – deploy key? (INSTALL.md, step 1)"
    fi
elif [ ! -d "$HTDOCS/.git" ]; then
    say "Note: $HTDOCS contains Koken but is no git checkout (older setup) – see migrate-server.sh."
fi
if $AS_ROOT && [ "$(stat -c %U "$HTDOCS")" != www-data ]; then
    fail "$HTDOCS does not belong to www-data – fix with: chown -R www-data:www-data $HTDOCS"
fi

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
if [ -f "$HTDOCS/storage/configuration/database.php" ]; then
    say "Koken is running: http://localhost:$PORT/   (admin: http://localhost:$PORT/admin/)"
else
    say "Done. Open the installer to finish the setup in your browser:"
    echo
    echo "    http://localhost:$PORT/install/?token=$TOKEN"
    echo
    echo "(On a server, replace localhost with its domain name.)"
fi
echo
if $AS_ROOT; then
    echo "Updates:  Docker setup  sudo $PWD/update.sh"
    echo "          Koken         sudo -u www-data -H $PWD/update-app.sh $HTDOCS"
else
    echo "Updates:  ./update.sh (Docker setup)  ·  ./update-app.sh (Koken, themes)"
fi
