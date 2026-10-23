#!/bin/sh
# Replay admin console write operations (as the console sends them) against PHP 8.5.
S=${IMG_DIR:-$(dirname "$0")}; B="http://localhost:${PORT:-8086}/api.php?/"; J=$S/cookies-admin.txt; rm -f $J
c() { m=$1; u=$2; shift 2; printf "%-6s %-48s " "$m" "$u"; curl -s -m 120 -A KokenTest -b $J -c $J -H 'X-Koken-Auth: cookie' -o $S/last.json -w "%{http_code}" "$B$u" "$@"; printf " %s\n" "$(head -c 90 $S/last.json | tr '\n' ' ')"; }
put() { u=$1; shift; c PUT "$u" -d _method=PUT "$@"; }
del() { u=$1; shift; c DELETE "$u" -d _method=DELETE "$@"; }
post() { u=$1; shift; c POST "$u" -X POST "$@"; }
post sessions -d email=test@example.com -d password=test12345
post content -F name=a.jpg -F file=@$S/img/test1.jpg -F visibility=public -F license=all -F max_download=none
post content -F name=b.jpg -F file=@$S/img/test2.jpg -F visibility=public
put  content/1 -d title=Erstes -d 'caption=Bildunterschrift mit <em>HTML</em>' -d 'tags=berlin,ubahn' -d visibility=unlisted -d license=y,s -d max_download=large -d 'focal_point={"x":30,"y":60}'
put  content/2 -d rotate=90
put  content/2 -d reset_internal_id=1
put  content/1 -d visibility=public
post albums -d title=Album1 -d album_type=0 -d visibility=public
post albums -d title=Set1 -d album_type=2 -d visibility=public
put  albums/1 -d title=Album-Eins -d summary=Kurz -d description=Lang -d tags=reise -d sort=manual
post albums/1/content/1,2
post albums/2/content/1
post albums/1/covers/2
put  albums/1/content/order:2,1
put  albums/order:2,1
post categories -d title=Kategorie
put  categories/1 -d title=Kategorie-X
put  categories/1/content/1,2
post categories/1/albums/1
post text -d title=Essay1 -d page_type=essay
post text -d title=Seite1 -d page_type=page
put  text/1/render:0 -d 'draft=<p>Entwurf</p>' -d draft_title=Essay1
put  text/1/render:0 -d 'content=<p>Hallo [koken_photo id="1"] Welt</p>' -d title=Essay1 -d published=1 -d tags=blog
post text/1/feature/1
post text/1/topics/1
post text/featured/1
put  categories/1/essays/1
post favorites/1,2
put  favorites/order:2,1
post content/featured/1
post albums/featured/1
put  site/set_order -d type=favorite -d order=1,2
put  tags/1 -d name=berlin-mitte
put  users/1 -d first_name=Testa -d last_name=User -d email=test@example.com -d public_display=both -d public_first_name=Testa -d public_last_name=User -d twitter=@foo
post users/verify_password -d password=test12345
put  settings -d site_title=Testseite -d site_tagline=Tag -d site_timezone=Europe/Berlin -d site_hidpi=true -d enable_site_cache=true -d image_processing_library=imagick
post plugins -d path=font-loader-5b6016ae-9d1a-2336-78c4-63dbb74d39b3
post plugins -d path=password-protect-fbfd75bc-7550-758d-0e79-1a39ca29f2b6
c GET plugins
post drafts -d theme=axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089 -d refresh=true
c GET site/draft:true
DRAFT=$(curl -s -A KokenTest -b $J -H 'X-Koken-Auth: cookie' "${B}drafts" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([x["id"] for x in d if "axis" in x["theme"]["path"]][0] if isinstance(d,list) else "")' 2>/dev/null); echo "draft=$DRAFT"
put  "site/draft:$DRAFT" --data-urlencode 'data={"custom_css":"body{color:red}"}'
post "site/publish/$DRAFT"
post trash/content:2
del  trash/content:2
post trash/albums:2
del  albums/trash
del  content/featured/1
del  favorites/2
del  albums/1/content/2
del  categories/1/content/2
del  text/2
post system/clear_caches
del  content/cache
c GET content
c GET albums
c GET text
c GET site
del  sessions
