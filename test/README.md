# Test environments for the PHP 8.5 port

`docker-compose.php85.yml` starts, separate from the regular setup:

| Service | Port | Code | Purpose |
|---|---|---|---|
| `web85` | 8086 | current `src/htdocs` (copied by `sync-code.sh`) | PHP 8.5.12, logs **every** notice/deprecation to `/tmp/koken85.log` in the container (`debug-prepend.php`), even though Koken calls `error_reporting(0)` |
| `web74` | 8074 | **original** code from the baseline commit (`sync-baseline-74.sh`) | PHP 7.4 reference |
| `db85` | – | – | MariaDB, shared by both |

Both web containers share one database and one `storage` volume, so the same data can be
rendered by the old and the new code.

```bash
cd test
docker compose -f docker-compose.php85.yml up -d --build
./sync-code.sh                 # after every code change
./sync-baseline-74.sh          # once
./fresh-install.sh             # new empty installation (DB + storage) via install/complete
IMG_DIR=/path/with/test1.jpg+test2.jpg ./admin-replay.sh   # admin console write calls
./compare.sh / /albums/ '/api.php?/content' …                # 7.4 vs 8.5 output diff
docker exec koken85-apache cat /tmp/koken85.log              # PHP messages
```

The code is copied into a Linux volume instead of bind-mounted: macOS bind mounts are
case-insensitive and cache differently spelled file names separately, which hides changes.

`fresh-install.sh` copies the themes/plugins of the existing installation
(`src/htdocs/storage/themes|plugins`) into the test storage – adjust the names if needed.
