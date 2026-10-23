#!/usr/bin/env bash
#
# One-time migration of an existing Koken server (old layout: PHP 7.4 image, Koken
# code copied into src/htdocs by hand) to the new layout:
#   - this repository (Docker setup) updated via git pull
#   - src/htdocs = git checkout of KOKEN_REPO (Koken for PHP 8.5)
#   - PHP 8.5 image
# Photos, themes, plugins, configuration (src/htdocs/storage) and the database are
# not modified. A backup and a rollback script are created first.
#
# The script is part of the NEW version of this repository, so on the server run it
# before pulling:
#   git fetch origin
#   git show origin/master:migrate-server.sh > /tmp/migrate-server.sh
#   bash /tmp/migrate-server.sh --host urbanphotography.berlin            # dry run
#   bash /tmp/migrate-server.sh --host urbanphotography.berlin --apply    # migrate
#
# Options:
#   --apply          really migrate (default: dry run, nothing is changed)
#   --host NAME      domain of the site, used for the checks (Host header)
#   --dir PATH       repository directory (default: current directory)
#   --backup PATH    backup directory (default: ../koken-backup-<date> next to the repo)
#   --remote NAME    git remote of this repository (default: origin)
#   --branch NAME    branch of this repository to pull (default: master)
#
set -euo pipefail

APPLY=false; SITE_HOST=""; ROOT="$PWD"; BACKUP=""; REMOTE=origin; BRANCH=master
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --host) SITE_HOST="$2"; shift ;;
        --dir) ROOT="$2"; shift ;;
        --backup) BACKUP="$2"; shift ;;
        --remote) REMOTE="$2"; shift ;;
        --branch) BRANCH="$2"; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if $APPLY; then "$@"; else info "[dry run] $*"; fi; }

cd "$ROOT" || fail "Directory $ROOT not found."
ROOT=$(pwd)

get_env() { grep -E "^$1=" .env 2>/dev/null | tail -n 1 | cut -d= -f2- || true; }
set_env() {
    local tmp; tmp=$(mktemp)
    if grep -q "^$1=" .env; then
        awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' .env > "$tmp"
    else
        cat .env > "$tmp"; [ -n "$(tail -c 1 .env)" ] && echo >> "$tmp"; printf '%s=%s\n' "$1" "$2" >> "$tmp"
    fi
    cat "$tmp" > .env; rm -f "$tmp"
}

# =============================================================================
say "1. Checks"
# =============================================================================
[ -d .git ] && [ -f docker-compose.yml ] || fail "$ROOT is not the Docker repository (no .git / docker-compose.yml). Use --dir."
[ -f .env ] || fail "No .env in $ROOT."
command -v git >/dev/null || fail "git is missing."
command -v curl >/dev/null || fail "curl is missing."
if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then COMPOSE=(docker-compose)
else fail "Docker Compose is missing."; fi

HTDOCS=$(get_env APACHE_HTDOCS)
HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(get_env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; esac
STORAGE="$HTDOCS/storage"
APP_NAME=$(get_env APP_NAME); APP_NAME=${APP_NAME:-koken}
PORT=$(get_env APACHE_PORT); PORT=${PORT:-8080}
DB_NAME=$(get_env MYSQL_DATABASE)

[ -f "$HTDOCS/index.php" ] || fail "$HTDOCS/index.php not found – is Koken installed in $HTDOCS?"
[ -f "$STORAGE/configuration/database.php" ] || fail "$STORAGE/configuration/database.php not found."
[ ! -d "$HTDOCS/.git" ] || fail "$HTDOCS is already a git checkout – this server seems to be migrated already."
info "repository:   $ROOT ($(git rev-parse --short HEAD), branch $(git rev-parse --abbrev-ref HEAD))"
info "Koken:        $HTDOCS"
info "storage:      $(du -sh "$STORAGE" | cut -f1)  (cache: $(du -sh "$STORAGE/cache" 2>/dev/null | cut -f1 || echo -))"
info "web port:     $PORT, containers: $APP_NAME-apache / $APP_NAME-mariadb"

if [ -f "$STORAGE/configuration/user_setup.php" ] && grep -qE "^\s*define\(\s*'LOOPBACK_HOST_HEADER'\s*,\s*true" "$STORAGE/configuration/user_setup.php"; then
    warn "LOOPBACK_HOST_HEADER is enabled in user_setup.php. Behind an HTTPS reverse proxy this breaks Koken's internal requests."
fi

CONF_DIR="$(get_env MARIADB_LOCAL_DIR)$(get_env MARIADB_CONF_DIR)"
if [ -n "$(get_env MARIADB_CONF_DIR)" ] && [ -d "$CONF_DIR" ] && [ -n "$(ls -A "$CONF_DIR" 2>/dev/null)" ]; then
    warn "$CONF_DIR contains MariaDB config files – the new docker-compose.yml no longer mounts it (add it in docker-compose.override.yml if you need it)."
fi

say "Fetching the new versions"
git fetch -q "$REMOTE" "$BRANCH" || fail "git fetch $REMOTE $BRANCH failed."
NEW_A="$REMOTE/$BRANCH"
git cat-file -e "$NEW_A:docker-compose.yml" || fail "$NEW_A has no docker-compose.yml."
info "this repository: $(git rev-parse --short HEAD) -> $(git rev-parse --short "$NEW_A")"

KOKEN_REPO=$(get_env KOKEN_REPO); KOKEN_BRANCH=$(get_env KOKEN_BRANCH)
[ -n "$KOKEN_REPO" ] || KOKEN_REPO=$(git show "$NEW_A:.env.dist" 2>/dev/null | grep -E '^KOKEN_REPO=' | cut -d= -f2-)
KOKEN_BRANCH=${KOKEN_BRANCH:-master}
[ -n "$KOKEN_REPO" ] || fail "KOKEN_REPO unknown (neither in .env nor in .env.dist of $NEW_A)."

TMPGIT=$(mktemp -d)
trap 'rm -rf "$TMPGIT"' EXIT
git init -q --bare "$TMPGIT/koken.git"
git --git-dir="$TMPGIT/koken.git" fetch -q "$KOKEN_REPO" "$KOKEN_BRANCH:refs/heads/$KOKEN_BRANCH" || fail "Cannot fetch $KOKEN_REPO ($KOKEN_BRANCH)."
info "Koken code:      $KOKEN_REPO ($KOKEN_BRANCH, $(git --git-dir="$TMPGIT/koken.git" rev-parse --short "$KOKEN_BRANCH"))"

say "2. Local changes in $HTDOCS (compared with the original Koken 0.22.24)"
BASE=$(git --git-dir="$TMPGIT/koken.git" log --format=%H --grep='add original Koken 0.22.24' "$KOKEN_BRANCH" | tail -n 1)
MODIFIED=()
if [ -z "$BASE" ]; then
    warn "Original Koken commit not found in $KOKEN_REPO – skipping this check."
else
    export GIT_DIR="$TMPGIT/koken.git" GIT_WORK_TREE="$ROOT/$HTDOCS" GIT_INDEX_FILE="$TMPGIT/index"
    git read-tree "$BASE"
    git update-index -q --refresh >/dev/null 2>&1 || true
    while IFS=$'\t' read -r status file; do
        case "$status:$file" in
            D:app/application/controllers/install.php) ;;   # deleted after every installation – expected
            M:*) MODIFIED+=("$file") ;;
            D:*) info "missing on the server (will be added): $file" ;;
        esac
    done < <(git diff-files --name-status)
    EXTRA=$(cd "$ROOT/$HTDOCS" && git ls-files --others --exclude-standard -- . ':!storage' | grep -v '\.DS_Store$' || true)
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    if [ ${#MODIFIED[@]} -eq 0 ]; then
        info "no modified Koken files – nothing of yours gets overwritten."
    else
        warn "${#MODIFIED[@]} file(s) differ from the original and will be REPLACED by the new version (a copy goes into the backup):"
        printf '      %s\n' "${MODIFIED[@]}"
    fi
    [ -z "$EXTRA" ] || { info "additional files (not part of Koken, they stay untouched):"; printf '      %s\n' $EXTRA; }
fi

FREE_KB=$(df -Pk "$ROOT/.." | awk 'NR == 2 { print $4 }')
kb() { local v; v=$(du -sk "$1" 2>/dev/null | cut -f1); echo "${v:-0}"; }
NEED_KB=$(( $(kb "$STORAGE") - $(kb "$STORAGE/cache") + $(kb "$HTDOCS") - $(kb "$STORAGE") + 512000 ))
info "free disk space next to the repository: $((FREE_KB / 1024)) MB, backup needs about $((NEED_KB / 1024)) MB"
[ "$FREE_KB" -gt "$NEED_KB" ] || fail "Not enough disk space for the backup."

# =============================================================================
say "3. Backup"
# =============================================================================
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=${BACKUP:-$(dirname "$ROOT")/koken-backup-$STAMP}
OLD_COMMIT=$(git rev-parse HEAD)
WEB_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$APP_NAME-apache" 2>/dev/null || true)
info "backup directory: $BACKUP"
run mkdir -p "$BACKUP"
run cp -p .env "$BACKUP/env"
if docker ps --format '{{.Names}}' | grep -qx "$APP_NAME-mariadb"; then
    if $APPLY; then
        docker exec "$APP_NAME-mariadb" sh -c 'exec mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" --single-transaction --routines --databases "$0"' "$DB_NAME" | gzip > "$BACKUP/database.sql.gz"
        [ "$(gzip -dc "$BACKUP/database.sql.gz" | grep -c 'CREATE TABLE')" -gt 0 ] || fail "Database dump is empty – stopping, nothing was changed."
        info "database dump: $(du -h "$BACKUP/database.sql.gz" | cut -f1)"
    else
        info "[dry run] mariadb-dump $DB_NAME > $BACKUP/database.sql.gz"
    fi
else
    fail "Container $APP_NAME-mariadb is not running – the database cannot be dumped."
fi
run tar -C "$ROOT/$HTDOCS" --exclude=./storage -czf "$BACKUP/htdocs-code.tar.gz" .
run tar -C "$ROOT/$HTDOCS" --exclude=./storage/cache -czf "$BACKUP/storage.tar.gz" ./storage
if [ ${#MODIFIED[@]} -gt 0 ]; then
    run tar -C "$ROOT/$HTDOCS" -czf "$BACKUP/modified-koken-files.tar.gz" "${MODIFIED[@]}"
fi
if [ -n "$WEB_IMAGE" ]; then
    run docker tag "$WEB_IMAGE" "koken-rollback:$STAMP"
    info "web image $WEB_IMAGE tagged as koken-rollback:$STAMP"
fi

if $APPLY; then
    cat > "$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
# Restores the state before the migration of $STAMP (code + Docker setup).
# Photos and the database were not changed by the migration; restore them only if
# needed: storage.tar.gz / database.sql.gz in this directory.
set -euo pipefail
cd "$ROOT"
${COMPOSE[*]} down
git reset -q --hard $OLD_COMMIT
cp -p "$BACKUP/env" .env
rm -rf "$HTDOCS/.git"
tar -C "$HTDOCS" -xzf "$BACKUP/htdocs-code.tar.gz"
${WEB_IMAGE:+docker tag koken-rollback:$STAMP $WEB_IMAGE}
${COMPOSE[*]} up -d
echo "Rolled back to $OLD_COMMIT."
EOF
    chmod +x "$BACKUP/rollback.sh"
    info "rollback script: $BACKUP/rollback.sh"
fi

# =============================================================================
say "4. Update this repository ($NEW_A)"
# =============================================================================
# .env and src/htdocs/index.php were versioned in the old layout. The new version no
# longer contains them; untrack them first, so git pull keeps the server's files.
UNTRACK=()
for f in .env "$HTDOCS/index.php"; do
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 && UNTRACK+=("$f")
done
if [ ${#UNTRACK[@]} -gt 0 ]; then
    run git rm -q --cached "${UNTRACK[@]}"
    run git -c user.name=migrate-server -c user.email=migrate@localhost commit -q -m "Untrack server files (.env, Koken code) before migration"
fi
if $APPLY; then
    git -c user.name=migrate-server -c user.email=migrate@localhost merge -q --no-edit "$NEW_A" || fail "git merge failed – run $BACKUP/rollback.sh"
    [ -f .env ] || cp -p "$BACKUP/env" .env
    cmp -s .env "$BACKUP/env" || fail ".env changed unexpectedly – run $BACKUP/rollback.sh"
    info "now at $(git rev-parse --short HEAD)"
else
    info "[dry run] git merge $NEW_A"
fi

# New settings in .env (existing values are kept)
for kv in "KOKEN_REPO=$KOKEN_REPO" "KOKEN_BRANCH=$KOKEN_BRANCH" "APACHE_BIND=127.0.0.1"; do
    k=${kv%%=*}
    if [ -z "$(get_env "$k")" ]; then run set_env "$k" "${kv#*=}"; info "  .env: $kv"; fi
done

# =============================================================================
say "5. $HTDOCS -> git checkout of $KOKEN_REPO"
# =============================================================================
# Only files that belong to Koken are replaced; storage/ and other untracked files
# are never touched by git.
run git -C "$HTDOCS" init -q -b "$KOKEN_BRANCH"
run git -C "$HTDOCS" remote add origin "$KOKEN_REPO"
run git -C "$HTDOCS" fetch -q origin "$KOKEN_BRANCH"
run git -C "$HTDOCS" reset -q --hard "origin/$KOKEN_BRANCH"
run git -C "$HTDOCS" branch -q -u "origin/$KOKEN_BRANCH"
if $APPLY; then
    [ -f "$STORAGE/configuration/database.php" ] || fail "storage/configuration lost?! Restore with $BACKUP/rollback.sh and storage.tar.gz"
    info "Koken now at $(git -C "$HTDOCS" rev-parse --short HEAD); storage: $(du -sh "$STORAGE" | cut -f1)"
fi

# =============================================================================
say "6. Build and start the PHP 8.5 containers"
# =============================================================================
run "${COMPOSE[@]}" up -d --build

# =============================================================================
say "7. Check"
# =============================================================================
if $APPLY; then
    HDR=(); [ -n "$SITE_HOST" ] && HDR=(-H "Host: $SITE_HOST" -H "X-Forwarded-Proto: https")
    ok=false
    for _ in $(seq 1 60); do
        code=$(curl -s -o "$TMPGIT/home.html" -w '%{http_code}' ${HDR[@]+"${HDR[@]}"} "http://127.0.0.1:$PORT/" || true)
        if [ "$code" = 200 ] && [ "$(wc -c < "$TMPGIT/home.html")" -gt 1000 ]; then ok=true; break; fi
        sleep 3
    done
    php_version=$(docker exec "$APP_NAME-apache" php -r 'echo PHP_VERSION;' 2>/dev/null || echo "?")
    if $ok; then
        info "home page: HTTP 200, $(wc -c < "$TMPGIT/home.html") bytes – PHP $php_version"
        say "Done. Please check the site and the admin console in the browser."
        info "Later updates:  git pull  (Docker setup)  and  git -C $HTDOCS pull  (Koken)"
        info "Rollback:       $BACKUP/rollback.sh"
    else
        warn "The home page does not answer correctly (HTTP $code). Logs: ${COMPOSE[*]} logs web"
        fail "Check the site – to go back: $BACKUP/rollback.sh"
    fi
else
    say "Dry run finished – nothing was changed. Run again with --apply to migrate."
fi
