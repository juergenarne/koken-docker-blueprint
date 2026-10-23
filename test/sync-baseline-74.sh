#!/bin/sh
# Copy the ORIGINAL Koken code (baseline commit, before the PHP 8 port) into the
# PHP 7.4 reference container, for output comparisons with the PHP 8.5 version.
BASE=${1:-7f55f18}
cd "$(dirname "$0")/.." || exit 1
docker exec koken74-apache sh -c 'cd /var/www/html && find . -mindepth 1 -maxdepth 1 ! -name storage -exec rm -rf {} +'
git archive "$BASE" src/htdocs | docker exec -i koken74-apache tar -C /var/www/html -xf - --strip-components=2 --no-same-owner
docker exec koken74-apache sh -c 'chown -R www-data:www-data /var/www/html; rm -f /var/www/html/app/application/controllers/install.php'
