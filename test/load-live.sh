#!/bin/sh
# Load a dump of the live site + the real storage/ (without cache) into the test
# environment, so the PHP 7.4 reference and PHP 8.5 can render the real content.
# Usage: ./load-live.sh [dump.sql]   (default: newest file in dumbs/ or dumps/)
cd "$(dirname "$0")" || exit 1
SRC=../src/htdocs/storage
DUMP=${1:-$(ls -t dumbs/*.sql dumps/*.sql 2>/dev/null | head -n 1)}
[ -f "$DUMP" ] || { echo "No dump found"; exit 1; }
echo "dump: $DUMP"

./sync-code.sh

# Database: fresh "koken" DB, user kq (password with special characters, see fresh-install.sh)
docker exec -i koken85-mariadb mariadb -uroot -pkoken85root 2>&1 <<'SQL' | grep -v Warning
DROP DATABASE IF EXISTS koken;
CREATE DATABASE koken CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'kq'@'%' IDENTIFIED BY 'p\'a"s\\s$x';
GRANT ALL ON koken.* TO 'kq'@'%';
SQL
docker exec -i koken85-mariadb mariadb -uroot -pkoken85root koken < "$DUMP" 2>&1 | grep -v Warning

# Storage: everything except the (regenerated) cache and the real database credentials
docker exec koken85-apache sh -c 'cd /var/www/html/storage && rm -rf ./* && mkdir -p cache tmp'
COPYFILE_DISABLE=1 tar -C "$SRC" --exclude=./cache --exclude=./tmp --exclude=./configuration/database.php --exclude='.DS_Store' -cf - . \
  | docker exec -i koken85-apache tar -C /var/www/html/storage -xf - --no-same-owner

docker exec -i koken85-apache sh -c 'cat > /var/www/html/storage/configuration/database.php' <<'PHP'
<?php
	return array(
		'hostname' => 'db85',
		'database' => 'koken',
		'username' => 'kq',
		'password' => 'p\'a"s\\s$x',
		'prefix' => 'koken_',
		'socket' => ''
	);
PHP
# Docker port mapping needs the loopback host header
docker exec koken85-apache sh -c 'f=/var/www/html/storage/configuration/user_setup.php; grep -q "^\s*define(.LOOPBACK_HOST_HEADER" $f || printf "\n\tdefine(\047LOOPBACK_HOST_HEADER\047, true);\n" >> $f'
docker exec koken85-apache sh -c 'chown -R www-data:www-data /var/www/html/storage; : > /tmp/koken85.log; chmod 666 /tmp/koken85.log'
docker exec koken85-mariadb mariadb -ukq '-pp'"'"'a"s\s$x' koken -e 'SELECT (SELECT COUNT(*) FROM koken_content) content, (SELECT COUNT(*) FROM koken_albums) albums, (SELECT COUNT(*) FROM koken_text) texts, (SELECT COUNT(*) FROM koken_users) users' 2>/dev/null
