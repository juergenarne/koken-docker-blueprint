#!/bin/sh
# Reset the PHP 8.5 test installation and run Koken's install/complete endpoint.
SRC=/Users/entwicklung/devel/advanced/koken/src/htdocs
/Users/entwicklung/devel/advanced/koken/test/sync-code.sh
docker exec koken85-mariadb mariadb -uroot -pkoken85root -e 'DROP DATABASE IF EXISTS koken; CREATE DATABASE koken; GRANT ALL ON koken.* TO koken@"%";' 2>&1 | grep -v Warning
docker exec koken85-apache sh -c 'cd /var/www/html/storage && rm -rf ./* && mkdir -p configuration originals cache tmp plugins custom themes'
tar -C "$SRC/storage/themes" -cf - elementary axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089 | docker exec -i koken85-apache tar -C /var/www/html/storage/themes -xf -
tar -C "$SRC/storage/plugins" -cf - font-loader-5b6016ae-9d1a-2336-78c4-63dbb74d39b3 password-protect-fbfd75bc-7550-758d-0e79-1a39ca29f2b6 | docker exec -i koken85-apache tar -C /var/www/html/storage/plugins -xf -
docker exec -i koken85-apache sh -c 'cat > /var/www/html/storage/configuration/user_setup.php' <<'PHP'
<?php
	define('LOOPBACK_HOST_HEADER', true);
PHP
docker exec koken85-apache sh -c 'chown -R www-data:www-data /var/www/html/storage; : > /tmp/koken85.log; chmod 666 /tmp/koken85.log'
curl -s -m 180 -X POST 'http://localhost:8086/api.php?/install/complete' \
  --data-urlencode 'database[hostname]=db85' --data-urlencode 'database[database]=koken' \
  --data-urlencode 'database[username]=kq' --data-urlencode "database[password]=p'a\"s\\s\$x" \
  --data-urlencode 'first_name=Test' --data-urlencode 'last_name=User' --data-urlencode 'email=test@example.com' \
  --data-urlencode 'password=test12345' --data-urlencode 'timezone=Europe/Berlin' -w '\nHTTP %{http_code} %{time_total}s\n' | tail -c 400
