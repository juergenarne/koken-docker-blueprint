#!/bin/sh
# Copy ../src/htdocs (without storage/) into the PHP 8.5 test container.
# A real copy inside a Linux volume behaves like a production server
# (case-sensitive file system, no macOS bind-mount caching).
cd "$(dirname "$0")/../src/htdocs" || exit 1
docker exec koken85-apache sh -c 'cd /var/www/html && find . -mindepth 1 -maxdepth 1 ! -name storage -exec rm -rf {} +'
COPYFILE_DISABLE=1 tar --exclude=./storage --exclude='.DS_Store' -cf - . | docker exec -i koken85-apache tar -C /var/www/html -xf - --no-same-owner
docker exec koken85-apache sh -c 'chown -R www-data:www-data /var/www/html'
