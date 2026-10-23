#!/bin/sh
# Regression check: fetch each URL from the PHP 7.4 reference (original code)
# and from PHP 8.5 (ported code) with identical Host header and shared DB/storage,
# then diff the responses. Usage: ./compare.sh [-a cookiefile] /url1 /url2 ...
OUT=${OUT:-/tmp/koken-compare}; mkdir -p "$OUT"; rm -f "$OUT"/*
AUTH=""; if [ "$1" = "-a" ]; then AUTH="-H X-Koken-Auth:cookie -b $2"; shift 2; fi
purge() { docker exec koken85-apache sh -c 'rm -rf /var/www/html/storage/cache/api/* /var/www/html/storage/cache/site/* /var/www/html/storage/cache/plugins/* 2>/dev/null; true'; }
fails=0
for u in "$@"; do
  n=$(echo "$u" | tr -c 'a-zA-Z0-9\n' '_')
  for v in 74 85; do
    [ $v = 74 ] && p=8074 || p=8086
    purge
    curl -s -m 120 $AUTH -H 'Host: koken.test' -o "$OUT/$n.$v" -w "%{http_code}" "http://localhost:$p$u" > "$OUT/$n.$v.code"
    # normalise volatile parts (timings, cache busters, nonces)
    perl -pi -e 's/\b1[6-9]\d{8}\b/TS/g; s/[0-9a-f]{32}/HASH/g; s/"(time|elapsed|timer|ms)":[0-9.]+/"$1":X/g' "$OUT/$n.$v"
  done
  c74=$(cat "$OUT/$n.74.code"); c85=$(cat "$OUT/$n.85.code")
  if [ "$c74" = "$c85" ] && cmp -s "$OUT/$n.74" "$OUT/$n.85"; then
    echo "SAME  $c85  $(wc -c < "$OUT/$n.85" | tr -d ' ')B  $u"
  else
    fails=$((fails+1))
    echo "DIFF  7.4:$c74/$(wc -c < "$OUT/$n.74" | tr -d ' ')B  8.5:$c85/$(wc -c < "$OUT/$n.85" | tr -d ' ')B  $u"
  fi
done
echo "differences: $fails"
