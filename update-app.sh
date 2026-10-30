#!/usr/bin/env bash
#
# Updates the application, without Docker, as the owner of the web root:
#   1. Koken (the web root, checkout of KOKEN_REPO)       git pull
#   2. themes and plugins that are git checkouts          git pull
#      (storage/themes/*/, storage/plugins/*/ with a .git folder)
#   3. Koken's API/site cache                             cleared
#
# On a server the web root and the deploy keys belong to www-data, which has no Docker
# rights and never needs root:
#   sudo -u www-data -H /opt/koken/<domain>/update-app.sh /var/www/htdocs/<domain>
# Locally: ./update-app.sh   (web root: APACHE_HTDOCS from .env)
#
# The Docker setup (containers, PHP, database) is updated by root: ./update.sh
# Photos, configuration (storage/) and the database are never touched.
#
set -euo pipefail

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || fail "Do not run this as root – the web root belongs to www-data: sudo -u www-data -H $0 <web root>"

if [ $# -gt 0 ]; then
    WEB=$1
else
    # no argument: APACHE_HTDOCS from the .env next to this script (not readable for www-data)
    HERE=$(cd "$(dirname "$0")" && pwd)
    [ -r "$HERE/.env" ] || fail "Usage: $0 <web root>   (e.g. /var/www/htdocs/<domain>)"
    WEB=$(grep -E '^APACHE_HTDOCS=' "$HERE/.env" | tail -n 1 | cut -d= -f2- || true)
    case "$WEB" in ""|*'$'*) WEB=./src/htdocs ;; esac
    case "$WEB" in /*) ;; *) WEB="$HERE/${WEB#./}" ;; esac
fi
[ -f "$WEB/index.php" ] && [ -d "$WEB/.git" ] || fail "$WEB is not a Koken checkout."
[ -w "$WEB/.git" ] || fail "No write access to $WEB – run as its owner: sudo -u www-data -H $0 $WEB"

say "Koken ($WEB):"
git -C "$WEB" pull --ff-only

shopt -s nullglob
for dir in "$WEB"/storage/themes/*/ "$WEB"/storage/plugins/*/; do
    [ -d "$dir.git" ] || continue
    dir=${dir%/}
    say "$(basename "$(dirname "$dir")")/$(basename "$dir"):"
    git -C "$dir" pull --ff-only
done

say "Clearing Koken's API and page cache …"
rm -rf "$WEB"/storage/cache/api/* "$WEB"/storage/cache/site/* "$WEB"/storage/cache/plugins/*

say "Done: Koken $(git -C "$WEB" rev-parse --short HEAD)"
