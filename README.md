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

1. creates `.env` from `.env.dist` with random database passwords and an installer token,
2. clones Koken ([koken2026-installer](https://github.com/juergenarne/koken2026-installer),
   `KOKEN_REPO` in `.env`) into `src/htdocs`,
3. builds the PHP 8.5 image and starts the containers,
4. prints the link to the web installer, e.g. `http://localhost:8080/install/?token=…`.

Open the link, answer a few questions (database – prefilled from Docker –, your name,
e-mail, password, time zone) and Koken is ready. Sign in at `/admin/`.

Options: `./setup.sh -p 8085` (other port), `./setup.sh -y` (no questions).

## Two repositories

| Repository | Content | On the server |
|---|---|---|
| **koken-docker-blueprint** (this one) | Docker setup: `Dockerfile`, `docker-compose.yml`, `.env.dist`, `config/`, scripts | `git pull` |
| **koken2026-installer** | Koken for PHP 8.5 + web installer (the web root) | cloned into `src/htdocs`, `git pull` |

Your photos, themes, plugins and configuration live in `src/htdocs/storage/`, the
database in `mariadb/`. Neither is part of a repository, so pulling never touches them.

## Updates

Change Koken in `src/htdocs` (it is a checkout of koken2026-installer), commit and push.
Then, on every installation:

```bash
./update.sh
```

It pulls both repositories, rebuilds the containers only when the Docker setup changed,
and clears Koken's caches. PHP picks up code changes immediately (no restart needed).

## Migrating a server with the old layout

Servers set up before the split (PHP 7.4, Koken copied into `src/htdocs` by hand, `.env`
versioned) are migrated once with `migrate-server.sh`. Do **not** use `git pull` there
directly: it would refuse to run, and forcing it (`git stash -u`, `git clean`,
`git checkout -f`) can remove `src/htdocs/storage` and `mariadb/`.

```bash
cd /path/to/koken-docker-blueprint
git fetch origin
git show origin/master:migrate-server.sh > /tmp/migrate-server.sh
bash /tmp/migrate-server.sh --host your-domain.tld            # dry run: checks, shows what would happen
bash /tmp/migrate-server.sh --host your-domain.tld --apply    # backup, migrate, check
```

The dry run lists Koken files that were changed on the server (they are replaced, a copy
goes into the backup). The backup directory (next to the repository) contains a database
dump, `storage/` (without cache), the old code, `.env` and `rollback.sh`; the old web image
is tagged `koken-rollback:<date>`.

## What is where

| Path | Content |
|---|---|
| `Dockerfile` | PHP 8.5 + Apache image with GD, Imagick, ImageMagick, exif, intl, zip, mysqli (`--build-arg INSTALL_FFMPEG=true` for video support) |
| `docker-compose.yml` | `web` (Apache/PHP) and `db` (MariaDB) |
| `.env.dist` | All settings; copied to `.env` by `setup.sh` (`.env` is not committed) |
| `config/php.ini` | PHP settings (memory, upload size, no error display) |
| `config/apache-koken.conf` | Apache settings Koken needs behind a port mapping (see below) |
| `docker/entrypoint.sh` | Fixes file permissions of `storage/` on container start |
| `setup.sh` / `update.sh` | first installation / updates |
| `migrate-server.sh` | one-time migration of servers with the old layout |
| `src/htdocs/` | Koken itself – checkout of koken2026-installer, **not in this repository** |
| `src/htdocs/install/` | Web installer, incl. the default theme *Elementary* |
| `src/htdocs/storage/` | Created by the installer: photos, cache, themes, plugins, configuration – **not in git** |
| `mariadb/` | Database files – **not in git** |
| `test/` | Test environments and scripts used for the PHP 8.5 port (see `test/README.md`) |

## Installing without Docker

Requirements: Apache with `mod_rewrite` (or another web server), PHP ≥ 8.1 (8.5 recommended)
with mysqli, curl, mbstring, zip, exif and GD or Imagick, and a MySQL/MariaDB database.

Clone koken2026-installer into the web root and open `/install/`. The installer checks the
requirements, including whether the server can reach itself over HTTP – Koken's site and
image generation call its own API that way.

## Notes

**Loopback requests.** Koken requests its own API via HTTP, using the host name of the
current request. The installer checks which way works and configures it:

- *Behind a reverse proxy with a real domain* (e.g. nginx + HTTPS → `127.0.0.1:8080`):
  the domain reaches the container through the proxy – nothing to configure.
  `LOOPBACK_HOST_HEADER` must **not** be set here (Koken would send HTTPS to port 80).
- *Direct access via a port mapping* (e.g. `http://localhost:8080` on your machine):
  `localhost:8080` does not exist inside the container, so the installer sets
  `LOOPBACK_HOST_HEADER` in `storage/configuration/user_setup.php`; the image sets
  `UseCanonicalPhysicalPort On` for it.

**Web port.** It is bound to `127.0.0.1` (`APACHE_BIND`), so behind a reverse proxy the
container is not reachable from the internet directly. Set `APACHE_BIND=0.0.0.0` to
reach it from other machines.

**Upgrading an existing Koken installation** (e.g. from PHP 7.4): no database migration
is needed – see *Migrating a server with the old layout*.

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
