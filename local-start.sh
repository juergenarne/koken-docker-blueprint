#!/usr/bin/env bash
#
# Starts the local development copy of Koken and opens it in the browser.
#
#   - clones Koken into src/htdocs if it is missing
#   - first start with an existing storage/ (copied from a server): takes the database
#     credentials for .env from storage/configuration/database.php
#   - starts the containers and waits until database and web server are ready
#   - imports the newest dump from test/dumbs/ or test/dumps/ if the database is empty
#   - clears Koken's caches, so code changes show up immediately
#   - opens the site (or the installer, if Koken is not installed yet)
#
# Usage: ./local-start.sh [options]
#   --dump FILE   import this SQL dump (replaces the local database)
#   --fresh-db    import the newest dump again (replaces the local database)
#   --no-open     do not open the browser
#   --stop        stop the local containers (data is kept)
#
set -euo pipefail
cd "$(dirname "$0")"

DUMP=""; FRESH=false; OPEN=true
while [ $# -gt 0 ]; do
    case "$1" in
        --dump) DUMP="$2"; FRESH=true; shift ;;
        --fresh-db) FRESH=true ;;
        --no-open) OPEN=false ;;
        --stop) docker compose down; exit 0 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

docker info >/dev/null 2>&1 || fail "Docker is not running (start Docker Desktop)."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is missing."
[ -f .env ] || { cp .env.dist .env; chmod 600 .env; say "Created .env from .env.dist"; }

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
random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-24}"; }

HTDOCS=$(get_env APACHE_HTDOCS); HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(get_env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; esac
APP_NAME=$(get_env APP_NAME); APP_NAME=${APP_NAME:-koken}
PORT=$(get_env APACHE_PORT); PORT=${PORT:-8080}
DB_DIR="$(get_env MARIADB_LOCAL_DIR)$(get_env MARIADB_DATA_DIR)"; DB_DIR=${DB_DIR:-./mariadb/data/lib}
DB_CONFIG="$HTDOCS/storage/configuration/database.php"
URL="http://localhost:$PORT"

# --- Koken code ------------------------------------------------------------------
if [ ! -f "$HTDOCS/index.php" ]; then
    REPO=$(get_env KOKEN_REPO); BRANCH=$(get_env KOKEN_BRANCH)
    [ -n "$REPO" ] || REPO=$(grep -E '^KOKEN_REPO=' .env.dist | cut -d= -f2-)
    say "Cloning Koken ($REPO) into $HTDOCS …"
    if [ -d "$HTDOCS" ] && [ -n "$(ls -A "$HTDOCS")" ]; then
        git -C "$HTDOCS" init -q -b "${BRANCH:-master}"
        git -C "$HTDOCS" remote add origin "$REPO"
        git -C "$HTDOCS" fetch -q origin "${BRANCH:-master}"
        git -C "$HTDOCS" checkout -q -B "${BRANCH:-master}" "origin/${BRANCH:-master}"
    else
        mkdir -p "$(dirname "$HTDOCS")"
        git clone -q --branch "${BRANCH:-master}" "$REPO" "$HTDOCS"
    fi
fi

# --- first start: database credentials --------------------------------------------
if [ ! -d "$DB_DIR" ]; then
    if [ -f "$DB_CONFIG" ]; then
        # storage/ comes from an existing installation: the new local database must use
        # the credentials Koken expects (read with the PHP of the web image).
        say "First start: taking the database credentials from $DB_CONFIG …"
        docker compose build -q web
        creds=$(docker compose run --rm --no-deps -T --entrypoint php -v "$PWD/$DB_CONFIG:/tmp/db.php:ro" web -r '
            $r = include "/tmp/db.php"; $c = isset($KOKEN_DATABASE) ? $KOKEN_DATABASE : $r;
            foreach (array("database", "username", "password", "prefix") as $k) echo base64_encode((string) $c[$k]), "\n";')
        { read -r db; read -r user; read -r pass; read -r prefix; } <<< "$creds"
        cp -p .env .env.bak
        set_env MYSQL_DATABASE "$(echo "$db" | base64 -d)"
        set_env MYSQL_USER "$(echo "$user" | base64 -d)"
        set_env MYSQL_PASSWORD "$(echo "$pass" | base64 -d)"
        set_env KOKEN_DB_PREFIX "$(echo "$prefix" | base64 -d)"
        echo "   (previous .env saved as .env.bak)"
    fi
    [ -n "$(get_env MYSQL_PASSWORD)" ]      || set_env MYSQL_PASSWORD "$(random 24)"
    [ -n "$(get_env MYSQL_ROOT_PASSWORD)" ] || set_env MYSQL_ROOT_PASSWORD "$(random 32)"
    [ -n "$(get_env KOKEN_INSTALL_TOKEN)" ] || set_env KOKEN_INSTALL_TOKEN "$(random 32)"
fi

# --- start -------------------------------------------------------------------------
say "Starting the containers …"
docker compose up -d --build 2>&1 | grep -vE '^#|^ *$' | grep -vE 'Building|Built|exporting|naming|writing|resolving|load|DONE|CACHED' || true

printf 'Waiting for the database '
for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$APP_NAME-mariadb" 2>/dev/null)" = healthy ] && break
    printf '.'; sleep 2
done
echo
db() { docker exec -i "$APP_NAME-mariadb" sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" "$@"' sh "$@"; }

# --- dump --------------------------------------------------------------------------
TABLES=$(db -N -e 'SHOW TABLES' 2>/dev/null | wc -l | tr -d ' ')
if $FRESH || [ "$TABLES" -eq 0 ]; then
    [ -n "$DUMP" ] || DUMP=$(ls -t test/dumbs/*.sql test/dumps/*.sql 2>/dev/null | head -n 1 || true)
    if [ -n "$DUMP" ] && [ -f "$DUMP" ] && [ -f "$DB_CONFIG" ]; then
        say "Importing $DUMP …"
        db -N -e 'SELECT CONCAT("DROP TABLE IF EXISTS `", table_name, "`;") FROM information_schema.tables WHERE table_schema = DATABASE()' | db
        db < "$DUMP"
        echo "   $(db -N -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()') tables"
    elif [ -n "$DUMP" ] && [ ! -f "$DB_CONFIG" ]; then
        echo "   (dump $DUMP not imported: no $DB_CONFIG – install Koken first)"
    fi
fi

printf 'Waiting for the web server '
for _ in $(seq 1 120); do
    curl -s -o /dev/null "$URL/install/index.php?ping=1" && break
    printf '.'; sleep 2
done
echo

# --- caches ------------------------------------------------------------------------
docker exec "$APP_NAME-apache" sh -c 'rm -rf /var/www/html/storage/cache/api/* /var/www/html/storage/cache/site/* /var/www/html/storage/cache/plugins/*' 2>/dev/null || true

# --- done --------------------------------------------------------------------------
if [ -f "$DB_CONFIG" ]; then
    TARGET="$URL/"
    say "Koken is running: $URL/   admin: $URL/admin/"
else
    TARGET="$URL/install/?token=$(get_env KOKEN_INSTALL_TOKEN)"
    say "Koken is not installed yet – installer: $TARGET"
fi
echo "   PHP $(docker exec "$APP_NAME-apache" php -r 'echo PHP_VERSION;')  ·  code: $HTDOCS ($(git -C "$HTDOCS" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -))"
echo "   stop: ./local-start.sh --stop   ·   reload the database from the dump: ./local-start.sh --fresh-db"

if $OPEN; then
    if command -v open >/dev/null 2>&1; then open "$TARGET"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$TARGET" >/dev/null 2>&1 &
    fi
fi
