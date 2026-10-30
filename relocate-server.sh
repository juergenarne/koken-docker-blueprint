#!/usr/bin/env bash
#
# One-time move of a Koken instance in the PHP 8.5 layout (this repository with Koken
# in src/htdocs) to the server layout with separate owners:
#   /opt/koken/<domain>         this repository, .env, mariadb/            root
#   /var/www/htdocs/<domain>    Koken (the web root) incl. storage/        www-data
# The theme Axis (storage/themes/axis-…) becomes a git checkout, so update-app.sh
# pulls it. Its files are kept: changes made on the server show up in git status.
# Photos, configuration and the database are not modified. A backup and a rollback
# script are created first. Old layout (PHP 7.4)? Run migrate-server.sh first.
#
# Requirements: deploy keys of www-data (INSTALL.md, step 1). Run as root from a copy
# outside the instance – this repository is moved:
#   curl -fsSL https://raw.githubusercontent.com/juergenarne/koken-docker-blueprint/master/relocate-server.sh -o /tmp/relocate-server.sh
#   sudo bash /tmp/relocate-server.sh --domain example.com --dir /var/www/htdocs/example.com            # dry run
#   sudo bash /tmp/relocate-server.sh --domain example.com --dir /var/www/htdocs/example.com --apply    # move
#
# Options:
#   --domain NAME        domain of the site: target directories and checks (required)
#   --dir PATH           current directory of the instance (default: current directory)
#   --apply              really move (default: dry run, nothing is changed)
#   --opt PATH           new directory of this repository (default: /opt/koken/<domain>)
#   --web PATH           new web root (default: /var/www/htdocs/<domain>)
#   --backup PATH        backup directory (default: /root/koken-relocate-<domain>-<date>)
#   --no-storage-backup  no tar of storage/ (photos are moved, never changed)
#   --koken-repo URL     Koken repository as www-data reaches it
#                        (default: git@github-koken2026:juergenarne/koken2026-installer.git)
#   --theme-repo URL     theme repository as www-data reaches it
#                        (default: git@github-koken-theme-axis:juergenarne/koken-theme-axis.git)
#   --no-theme           leave storage/themes/ as it is
#   --blueprint URL      this repository (default: https://github.com/juergenarne/koken-docker-blueprint.git)
#
set -euo pipefail

SELF=$(readlink -f "$0"); ARGS=("$@")
APPLY=false; DOMAIN=""; CUR="$PWD"; OPT=""; WEB=""; BACKUP=""; STORAGE_BACKUP=true; THEME=true
KOKEN_URL=git@github-koken2026:juergenarne/koken2026-installer.git
THEME_URL=git@github-koken-theme-axis:juergenarne/koken-theme-axis.git
BLUEPRINT_URL=https://github.com/juergenarne/koken-docker-blueprint.git
BRANCH=master
THEME_NAME=axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=true ;;
        --domain) DOMAIN="$2"; shift ;;
        --dir) CUR="$2"; shift ;;
        --opt) OPT="$2"; shift ;;
        --web) WEB="$2"; shift ;;
        --backup) BACKUP="$2"; shift ;;
        --no-storage-backup) STORAGE_BACKUP=false ;;
        --koken-repo) KOKEN_URL="$2"; shift ;;
        --theme-repo) THEME_URL="$2"; shift ;;
        --no-theme) THEME=false ;;
        --blueprint) BLUEPRINT_URL="$2"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33mWARNING:\033[0m %s\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if $APPLY; then "$@"; else info "[dry run] $*"; fi; }

[ "$(id -u)" = 0 ] || fail "Run as root: sudo bash $0 …"
[ -n "$DOMAIN" ] || fail "--domain is missing (e.g. --domain urbanphotography.berlin)."
CUR=$(cd "$CUR" 2>/dev/null && pwd -P) || fail "Directory $CUR not found."

# This repository is moved and updated while the script runs: continue from a copy.
case "$SELF" in
    "$CUR"/*) COPY=$(mktemp); cp "$SELF" "$COPY"; exec bash "$COPY" "${ARGS[@]}" ;;
esac
cd "$CUR"

OPT=${OPT:-/opt/koken/$DOMAIN}; WEB=${WEB:-/var/www/htdocs/$DOMAIN}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=${BACKUP:-/root/koken-relocate-$DOMAIN-$STAMP}

# git as root in a repository that belongs to someone else
rgit() { git -c safe.directory="$1" -C "$1" "${@:2}"; }
# as www-data, with its deploy keys (~www-data/.ssh)
web()  { (cd / && sudo -u www-data -H "$@"); }

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
for c in git docker sudo curl; do command -v $c >/dev/null || fail "$c is missing."; done
id www-data >/dev/null 2>&1 || fail "User www-data does not exist."
if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null; then COMPOSE=(docker-compose)
else fail "Docker Compose is missing."; fi

[ -d .git ] && [ -f docker-compose.yml ] && [ -f .env ] || fail "$CUR is not the Docker repository with a .env. Use --dir."
HTDOCS=$(get_env APACHE_HTDOCS); HTDOCS=${HTDOCS//\$\{APACHE_SRC\}/$(get_env APACHE_SRC)}
case "$HTDOCS" in ""|*'$'*) HTDOCS=src/htdocs ;; /*) fail "APACHE_HTDOCS is already absolute ($HTDOCS) – relocated already?" ;; esac
HTDOCS=${HTDOCS#./}
[ -f "$HTDOCS/index.php" ] || fail "$HTDOCS/index.php not found."
[ -d "$HTDOCS/.git" ] || fail "$HTDOCS is no git checkout – old layout: run migrate-server.sh first (MIGRATE.md)."
STORAGE="$HTDOCS/storage"
APP_NAME=$(get_env APP_NAME); APP_NAME=${APP_NAME:-koken}
PORT=$(get_env APACHE_PORT); PORT=${PORT:-8080}
DB_NAME=$(get_env MYSQL_DATABASE)
KOKEN_BRANCH=$(get_env KOKEN_BRANCH); KOKEN_BRANCH=${KOKEN_BRANCH:-master}
# the database files themselves (mounted as /var/lib/mysql, see docker-compose.yml) belong
# to MariaDB (UID 999) and keep their owner; everything around them becomes root's
DB_LOCAL=$(get_env MARIADB_LOCAL_DIR); DB_DATA=$(get_env MARIADB_DATA_DIR)
DB_DIR=${DB_LOCAL:-./mariadb/data}${DB_DATA:-/lib}
case "$DB_DIR" in /*) DB_REL="" ;; *) DB_REL=${DB_DIR#./} ;; esac   # relative: moves with this repository
info "instance:   $CUR  (owner $(stat -c %U "$CUR"))"
info "Koken:      $CUR/$HTDOCS  (owner $(stat -c %U "$CUR/$HTDOCS"), storage: $(du -sh "$STORAGE" | cut -f1))"
info "containers: $APP_NAME-apache / $APP_NAME-mariadb, port $PORT"
info "new:        $OPT  (root)"
info "            $WEB  (www-data)"

for n in "$APP_NAME-apache" "$APP_NAME-mariadb"; do
    docker ps --format '{{.Names}}' | grep -qx "$n" || fail "Container $n is not running."
done

[ ! -e "$OPT" ] || fail "$OPT exists already."
[ "$WEB" = "$CUR" ] || [ ! -e "$WEB" ] || fail "$WEB exists already."
case "$OPT/" in "$CUR"/*) fail "$OPT lies inside $CUR." ;; esac
case "$WEB/" in "$CUR"/*) [ "$WEB" = "$CUR" ] || fail "$WEB lies inside $CUR." ;; esac
# mv within one file system is a rename; across file systems it would copy all photos
existing() { local p=$1; while [ ! -d "$p" ]; do p=$(dirname "$p"); done; echo "$p"; }
for t in "$OPT" "$WEB"; do
    [ "$(stat -c %d "$CUR")" = "$(stat -c %d "$(existing "$(dirname "$t")")")" ] \
        || fail "$t is on another file system than $CUR – moving would copy everything. Choose --opt/--web on the same file system."
done

say "This repository"
OLD_COMMIT=$(rgit "$CUR" rev-parse HEAD)
OLD_URL=$(rgit "$CUR" remote get-url origin 2>/dev/null || true)
LOCAL_CHANGES=$(rgit "$CUR" --no-optional-locks status --porcelain --untracked-files=no)
if [ -n "$LOCAL_CHANGES" ]; then
    echo "$LOCAL_CHANGES" | sed 's/^/      /'
    fail "Local changes in versioned files of this repository – commit or undo them first (git diff)."
fi
NEW_COMMIT=$(git ls-remote "$BLUEPRINT_URL" "refs/heads/$BRANCH" | cut -f1)
[ -n "$NEW_COMMIT" ] || fail "Cannot reach $BLUEPRINT_URL."
info "$(rgit "$CUR" rev-parse --short HEAD) -> ${NEW_COMMIT:0:7}  ($BLUEPRINT_URL, origin was: ${OLD_URL:-none})"

say "Koken ($HTDOCS)"
KOKEN_OLD_URL=$(rgit "$CUR/$HTDOCS" remote get-url origin 2>/dev/null || true)
info "at $(rgit "$CUR/$HTDOCS" rev-parse --short HEAD), origin: ${KOKEN_OLD_URL:-none} -> $KOKEN_URL"
KOKEN_CHANGES=$(rgit "$CUR/$HTDOCS" --no-optional-locks status --porcelain --untracked-files=no | grep -v ' app/application/controllers/install\.php$' || true)
if [ -n "$KOKEN_CHANGES" ]; then
    warn "Koken files changed on the server (they stay; update-app.sh refuses to pull over them):"
    echo "$KOKEN_CHANGES" | sed 's/^/      /'
fi
web git ls-remote "$KOKEN_URL" "refs/heads/$KOKEN_BRANCH" >/dev/null 2>&1 \
    || fail "www-data cannot reach $KOKEN_URL – deploy key missing? (INSTALL.md, step 1)"
info "www-data reaches $KOKEN_URL"

THEME_DIR="$STORAGE/themes/$THEME_NAME"
if $THEME && [ ! -d "$THEME_DIR" ]; then
    info "no theme Axis in $STORAGE/themes – nothing to convert"; THEME=false
elif $THEME && [ -d "$THEME_DIR/.git" ]; then
    info "theme Axis is a git checkout already"; THEME=false
fi
TMPW=$(mktemp -d); chown www-data "$TMPW"
trap 'rm -rf "$TMPW"' EXIT
if $THEME; then
    say "Theme Axis ($THEME_DIR)"
    web git ls-remote "$THEME_URL" "refs/heads/$BRANCH" >/dev/null 2>&1 \
        || fail "www-data cannot reach $THEME_URL – deploy key missing? (INSTALL.md, step 1). Or skip with --no-theme."
    web git init -q --bare "$TMPW/theme.git"
    web git --git-dir="$TMPW/theme.git" fetch -q "$THEME_URL" "$BRANCH:refs/heads/$BRANCH"
    info "www-data reaches $THEME_URL ($(web git --git-dir="$TMPW/theme.git" rev-parse --short "$BRANCH"))"
    # Compare the server's files with the repository (content only). Read by root: the
    # files may not be readable for www-data yet.
    tgit() { GIT_DIR="$TMPW/theme.git" GIT_WORK_TREE="$CUR/$THEME_DIR" GIT_INDEX_FILE="$TMPW/index" \
             git -c safe.directory="$TMPW/theme.git" -c core.fileMode=false "$@"; }
    tgit read-tree "$BRANCH"
    tgit update-index -q --refresh >/dev/null 2>&1 || true
    THEME_DIFF=$(tgit diff-files --name-status)
    THEME_EXTRA=$(tgit ls-files --others | grep -v '\.DS_Store$' || true)
    if [ -z "$THEME_DIFF$THEME_EXTRA" ]; then
        info "identical to $BRANCH of the repository"
    else
        warn "the server's theme differs from the repository. Nothing is overwritten: after the move"
        info "these files show up as local changes (git status). Commit them to the theme repository"
        info "or discard them, otherwise update-app.sh cannot pull changes to the same files."
        [ -z "$THEME_DIFF" ]  || echo "$THEME_DIFF"  | sed 's/^/      /'
        [ -z "$THEME_EXTRA" ] || echo "$THEME_EXTRA" | sed 's/^/      ?\t/'
    fi
fi

kb() { local v; v=$(du -sk "$1" 2>/dev/null | cut -f1); echo "${v:-0}"; }
NEED_KB=512000
$STORAGE_BACKUP && NEED_KB=$(( NEED_KB + $(kb "$STORAGE") - $(kb "$STORAGE/cache") ))
FREE_KB=$(df -Pk "$(existing "$(dirname "$BACKUP")")" | awk 'NR == 2 { print $4 }')
info "backup: $BACKUP – needs about $((NEED_KB / 1024)) MB, free: $((FREE_KB / 1024)) MB"
[ "$FREE_KB" -gt "$NEED_KB" ] || fail "Not enough disk space for the backup (or use --no-storage-backup / --backup)."

# =============================================================================
say "2. Backup (the site keeps running)"
# =============================================================================
WEB_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$APP_NAME-apache" 2>/dev/null || true)
run mkdir -m 700 -p "$BACKUP"
run cp -p .env "$BACKUP/env"
if $APPLY; then
    docker exec "$APP_NAME-mariadb" sh -c 'exec mariadb-dump -uroot -p"${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" --single-transaction --routines --databases "$0"' "$DB_NAME" | gzip > "$BACKUP/database.sql.gz"
    [ "$(gzip -dc "$BACKUP/database.sql.gz" | grep -c 'CREATE TABLE')" -gt 0 ] || fail "Database dump is empty – stopping, nothing was changed."
    info "database dump: $(du -h "$BACKUP/database.sql.gz" | cut -f1)"
    # owners of all files (except the database), restored by rollback.sh
    find "$CUR" -path "$CUR/$DB_REL" -prune -o -printf '%U:%G\0%p\0' > "$BACKUP/owners"
else
    info "[dry run] mariadb-dump $DB_NAME > $BACKUP/database.sql.gz, owners of all files > $BACKUP/owners"
fi
if $STORAGE_BACKUP; then
    run tar -C "$CUR/$HTDOCS" --exclude=./storage/cache -czf "$BACKUP/storage.tar.gz" ./storage
fi
if $THEME; then
    run tar -C "$CUR/$STORAGE/themes" -czf "$BACKUP/theme-axis.tar.gz" "$THEME_NAME"
fi
if [ -n "$WEB_IMAGE" ]; then
    run docker tag "$WEB_IMAGE" "koken-rollback:relocate-$STAMP"
fi

if $APPLY; then
    cat > "$BACKUP/rollback.sh" <<EOF
#!/usr/bin/env bash
# Moves the instance back to $CUR (state before $STAMP).
# Photos and the database were not changed; for emergencies they are in this directory.
set -euo pipefail
[ ! -d "$OPT" ] || (cd "$OPT" && ${COMPOSE[*]} down) || true
if [ -d "$WEB" ] && [ -d "$OPT" ] && [ ! -e "$OPT/$HTDOCS" ]; then
    mkdir -p "$OPT/$(dirname "$HTDOCS")"; mv "$WEB" "$OPT/$HTDOCS"
fi
if [ -d "$OPT" ] && [ ! -e "$CUR" ]; then mv "$OPT" "$CUR"; fi
cd "$CUR"
git -c safe.directory="$CUR" reset -q --hard $OLD_COMMIT
${OLD_URL:+git -c safe.directory="$CUR" remote set-url origin "$OLD_URL"}
cp -p "$BACKUP/env" .env
${KOKEN_OLD_URL:+git -c safe.directory="$CUR/$HTDOCS" -C "$HTDOCS" remote set-url origin "$KOKEN_OLD_URL"}
$($THEME && echo "rm -rf \"$CUR/$THEME_DIR/.git\"" || true)
echo "restoring the owners of all files …"
while IFS= read -r -d '' owner && IFS= read -r -d '' path; do chown -h "\$owner" "\$path" 2>/dev/null || true; done < "$BACKUP/owners"
${WEB_IMAGE:+docker tag "koken-rollback:relocate-$STAMP" "$WEB_IMAGE"}
${COMPOSE[*]} up -d
echo "Rolled back to $CUR."
EOF
    chmod 700 "$BACKUP/rollback.sh"
    info "rollback script: $BACKUP/rollback.sh"
fi

# =============================================================================
say "3. Update this repository, build the image (the site keeps running)"
# =============================================================================
run rgit "$CUR" remote set-url origin "$BLUEPRINT_URL"
if $APPLY; then
    rgit "$CUR" fetch -q origin "$BRANCH" || fail "git fetch failed – nothing was changed (backup: $BACKUP)."
    if ! rgit "$CUR" merge-base --is-ancestor HEAD "origin/$BRANCH"; then
        # bookkeeping commits of migrate-server.sh change nothing – drop them
        base=$(rgit "$CUR" merge-base HEAD "origin/$BRANCH")
        rgit "$CUR" diff --quiet "$base" HEAD || fail "This repository has local commits with changes – run $BACKUP/rollback.sh and merge them first."
        rgit "$CUR" reset -q "$base"
    fi
    rgit "$CUR" merge -q --ff-only "origin/$BRANCH"
    rgit "$CUR" branch -q -u "origin/$BRANCH" 2>/dev/null || true
    info "now at $(rgit "$CUR" rev-parse --short HEAD)"
else
    info "[dry run] git pull (fast-forward) to ${NEW_COMMIT:0:7}"
fi
# the new docker-compose.yml mounts APACHE_HTDOCS as it is (relative paths need ./)
run set_env APACHE_HTDOCS "./$HTDOCS"
if $APPLY; then
    "${COMPOSE[@]}" build || fail "Building the image failed – the site still runs. Undo: $BACKUP/rollback.sh"
else
    info "[dry run] ${COMPOSE[*]} build"
fi

# =============================================================================
say "4. Move (the site is down for a few seconds)"
# =============================================================================
run "${COMPOSE[@]}" down
run mkdir -m 755 -p "$(dirname "$OPT")"
run mv "$CUR" "$OPT"
run mkdir -p "$(dirname "$WEB")"
run mv "$OPT/$HTDOCS" "$WEB"
[ "$(dirname "$HTDOCS")" = . ] || run rmdir "$OPT/$(dirname "$HTDOCS")" 2>/dev/null || true
if $APPLY; then cd "$OPT"; fi

# =============================================================================
say "5. Owners and settings"
# =============================================================================
run set_env APACHE_HTDOCS "$WEB"
run set_env KOKEN_REPO "$KOKEN_URL"
run chmod 600 .env
run find "$OPT" -path "$OPT/$DB_REL" -prune -o \( ! -user root -o ! -group root \) -exec chown -h root:root {} +
run chmod 755 "$OPT"
run chown -R www-data:www-data "$WEB"
run web git -C "$WEB" remote set-url origin "$KOKEN_URL"
if $THEME; then
    T="$WEB/storage/themes/$THEME_NAME"
    # becomes a checkout without touching the files (mixed reset)
    run web git -C "$T" init -q
    run web git -C "$T" remote add origin "$THEME_URL"
    run web git -C "$T" fetch -q origin "$BRANCH"
    run web git -C "$T" reset -q "origin/$BRANCH"
    run web git -C "$T" checkout -q -B "$BRANCH"
    run web git -C "$T" branch -q -u "origin/$BRANCH"
    if $APPLY; then
        changes=$(web git -C "$T" status --porcelain | wc -l | tr -d ' ')
        info "theme Axis is a checkout now ($changes local change(s): sudo -u www-data -H git -C $T status)"
    fi
fi

# =============================================================================
say "6. Start and check"
# =============================================================================
run "${COMPOSE[@]}" up -d
if $APPLY; then
    HDR=(-H "Host: $DOMAIN" -H "X-Forwarded-Proto: https")
    ok=false
    for _ in $(seq 1 60); do
        code=$(curl -s -o "$TMPW/home.html" -w '%{http_code}' "${HDR[@]}" "http://127.0.0.1:$PORT/" || true)
        if [ "$code" = 200 ] && [ "$(wc -c < "$TMPW/home.html")" -gt 1000 ]; then ok=true; break; fi
        sleep 3
    done
    $ok || fail "The home page does not answer correctly (HTTP $code). Logs: cd $OPT && ${COMPOSE[*]} logs web – back: $BACKUP/rollback.sh"
    info "home page: HTTP 200, $(wc -c < "$TMPW/home.html") bytes"
    git_code=$(curl -s -o /dev/null -w '%{http_code}' "${HDR[@]}" "http://127.0.0.1:$PORT/.git/config" || true)
    [ "$git_code" = 404 ] && info "/.git/config: 404" || warn "/.git/config answers $git_code (expected 404)"
    say "Done. Please check the site and the admin console in the browser."
    info "Updates:   sudo $OPT/update.sh"
    info "           sudo -u www-data -H $OPT/update-app.sh $WEB"
    info "Rollback:  $BACKUP/rollback.sh"
    info "Later:     rm -rf $BACKUP; docker rmi koken-rollback:relocate-$STAMP"
else
    say "Dry run finished – nothing was changed. Run again with --apply to move."
fi
