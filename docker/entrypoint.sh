#!/bin/sh
# Make sure Apache (www-data) can write where Koken needs to write:
#   storage/                                  images, cache, themes, plugins, configuration
#   .htaccess                                 pretty URL rules (written by the installer/settings)
#   app/application/controllers/install.php   deleted after the installation
set -e

ROOT=/var/www/html

mkdir -p "$ROOT/storage"

# Only walk the (possibly large) storage tree when something is not owned by www-data
if [ -n "$(find "$ROOT/storage" ! -user www-data -print -quit 2>/dev/null)" ]; then
    echo "koken: fixing ownership of storage/ (first start or files added from the host)"
    chown -R www-data:www-data "$ROOT/storage"
fi

[ -f "$ROOT/.htaccess" ] && chown www-data:www-data "$ROOT/.htaccess"
chown www-data:www-data "$ROOT" "$ROOT/app/application/controllers" 2>/dev/null || true

exec docker-php-entrypoint "$@"
