#!/bin/sh
# Make sure Apache (www-data) can write where Koken needs to write:
#   storage/                                  images, cache, themes, plugins, configuration
#   .htaccess                                 pretty URL rules (written by the installer/settings)
#   app/application/controllers/install.php   deleted after the installation
set -e

ROOT=/var/www/html

mkdir -p "$ROOT/storage"

# Only walk the (possibly large) storage tree when something is not owned by www-data.
# On a server the web root belongs to www-data anyway (same UID 33 as on Debian/Ubuntu
# hosts), so this does nothing there. git checkouts of themes/plugins (.git) are skipped:
# Apache never needs them, and Docker Desktop refuses to chown their read-only objects.
if [ -n "$(find "$ROOT/storage" -name .git -prune -o ! -user www-data -print -quit 2>/dev/null)" ]; then
    echo "koken: fixing ownership of storage/ (first start or files added from the host)"
    find "$ROOT/storage" -name .git -prune -o ! -user www-data -exec chown www-data:www-data {} + \
        || echo "koken: warning: could not change the owner of some files in storage/"
fi

[ -f "$ROOT/.htaccess" ] && chown www-data:www-data "$ROOT/.htaccess"
chown www-data:www-data "$ROOT" "$ROOT/app/application/controllers" 2>/dev/null || true

# Also listen on the host port of the port mapping, so Koken's internal requests to
# http://<host>:<port>/ from inside the container work (see config/apache-koken.conf)
if [ -n "${KOKEN_PUBLIC_PORT:-}" ] && [ "$KOKEN_PUBLIC_PORT" != 80 ] && ! grep -q "^Listen $KOKEN_PUBLIC_PORT\$" /etc/apache2/ports.conf; then
    echo "Listen $KOKEN_PUBLIC_PORT" >> /etc/apache2/ports.conf
fi

exec docker-php-entrypoint "$@"
