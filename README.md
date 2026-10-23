# Koken on PHP 8.5 – Docker package

[Koken](https://github.com/koken) 0.22.24 (photo publishing CMS), ported to run on
**PHP 8.5** (tested with 8.5.12), with a Docker setup (Apache + MariaDB) and a web installer.

## Quick start

```bash
git clone https://github.com/juergenarne/koken-docker-blueprint.git koken
cd koken
./setup.sh
```

`setup.sh`

1. creates `.env` from `.env.example` with random database passwords and an installer token,
2. builds the PHP 8.5 image and starts the containers,
3. prints the link to the web installer, e.g. `http://localhost:8080/install/?token=…`.

Open the link, answer a few questions (database – prefilled from Docker –, your name,
e-mail, password, time zone) and Koken is ready. Sign in at `/admin/`.

Options: `./setup.sh -p 8085` (other port), `./setup.sh -y` (no questions).

## What is where

| Path | Content |
|---|---|
| `Dockerfile` | PHP 8.5 + Apache image with GD, Imagick, ImageMagick, exif, intl, zip, mysqli (`--build-arg INSTALL_FFMPEG=true` for video support) |
| `docker-compose.yml` | `web` (Apache/PHP) and `db` (MariaDB) |
| `.env.example` | All settings; copied to `.env` by `setup.sh` (`.env` is not committed) |
| `config/php.ini` | PHP settings (memory, upload size, no error display) |
| `config/apache-koken.conf` | Apache settings Koken needs behind a port mapping (see below) |
| `docker/entrypoint.sh` | Fixes file permissions of `storage/` on container start |
| `src/htdocs/` | Koken itself |
| `src/htdocs/install/` | Web installer, incl. the default theme *Elementary* |
| `src/htdocs/storage/` | Created by the installer: photos, cache, themes, plugins, configuration – **not in git** |
| `mariadb/` | Database files – **not in git** |
| `test/` | Test environments and scripts used for the PHP 8.5 port (see `test/README.md`) |

## Installing without Docker

Requirements: Apache with `mod_rewrite` (or another web server), PHP ≥ 8.1 (8.5 recommended)
with mysqli, curl, mbstring, zip, exif and GD or Imagick, and a MySQL/MariaDB database.

Copy `src/htdocs/` to the web root and open `/install/`. The installer checks the
requirements, including whether the server can reach itself over HTTP – Koken's site and
image generation call its own API that way.

## Notes

**Loopback requests.** Koken requests its own API via HTTP. Behind a port mapping
(host port 8080 → container port 80) or a reverse proxy, the server address in the
`Host` header is not reachable from inside the container. The image therefore sets
`UseCanonicalPhysicalPort On`, and the installer writes `LOOPBACK_HOST_HEADER` to
`storage/configuration/user_setup.php` when it is needed.

**Upgrading an existing Koken installation** (e.g. from PHP 7.4): keep `storage/`
and the database, replace everything else in `src/htdocs/` with this version and
start the PHP 8.5 image. If Koken runs behind a Docker port mapping, add
`define('LOOPBACK_HOST_HEADER', true);` to `storage/configuration/user_setup.php`.
No database migration is needed.

**Database access from the host.** The database port is not published. To use a GUI
tool or `mysqldump` from the host, create `docker-compose.override.yml`:

```yaml
services:
  db:
    ports:
      - "127.0.0.1:3307:3306"
```

or use `docker compose exec db mariadb-dump -u root -p koken > backup.sql`.

**Backups** = `src/htdocs/storage/` + a database dump.

**Koken store.** store.koken.me no longer exists. Themes and plugins can still be
installed by copying them to `storage/themes/` and `storage/plugins/`. Calls to the store
(registration, plain-HTTP download fallback) were removed.

**Docker Desktop on macOS.** The file system is case-insensitive, while Koken (CodeIgniter)
loads some files with different capitalisation (`Datamapper.php` vs. `datamapper.php`).
If you edit PHP files of a running container and see stale code, restart the container.
Linux servers are not affected.

## Changes for PHP 8

See the git history (`git log`) for details. In short: removed functions (`each()`,
`create_function()`, magic quotes), method signatures, `count()`/`array_merge()` on objects,
named-argument pitfalls in `call_user_func_array()`, mysqli exceptions (PHP 8.1+),
cURL/GD handles as objects, dynamic properties (PHP 8.2), implicit nullable types (PHP 8.4),
and the PHP 8.5 deprecations (`curl_close()`, `imagedestroy()`, non-canonical casts, …).
Every change keeps the PHP 7.4 behaviour – the test suite compares the output of the
original code on PHP 7.4 with the ported code on PHP 8.5.
