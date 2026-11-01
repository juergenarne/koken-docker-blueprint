# Koken on PHP 8.5 – Docker package

[Koken](https://github.com/koken) 0.22.24 (photo publishing CMS), ported to run on
**PHP 8.5** (tested with 8.5.12), with a Docker setup (Apache + MariaDB) and a web installer.

## Quick start

Step-by-step guide (German, incl. nginx/HTTPS and the private repository): [INSTALL.md](INSTALL.md).

```bash
git clone https://github.com/juergenarne/koken-docker-blueprint.git koken
cd koken
./setup.sh
```

`setup.sh`

1. creates `.env` from `.env.dist` with random database passwords and an installer token,
2. clones Koken ([koken2026-installer](https://github.com/juergenarne/koken2026-installer),
   `KOKEN_REPO` in `.env`) into the web root (`APACHE_HTDOCS`, locally `./src/htdocs`),
3. builds the PHP 8.5 image and starts the containers,
4. prints the link to the web installer, e.g. `http://localhost:8080/install/?token=…`.

Open the link, answer a few questions (database – prefilled from Docker –, your name,
e-mail, password, time zone) and Koken is ready. Sign in at `/admin/`.

Options: `./setup.sh -p 8085` (other port), `./setup.sh -y` (no questions).

## Three repositories

| Repository | Content | On the server | Key |
|---|---|---|---|
| **koken-docker-blueprint** (this one, public) | Docker setup: `Dockerfile`, `docker-compose.yml`, `.env.dist`, `config/`, scripts | `/opt/koken/<domain>`, root | none (https) |
| **koken2026-installer** (private) | Koken for PHP 8.5 + web installer (the web root) | `/var/www/htdocs/<domain>`, www-data | deploy key of www-data |
| **koken-theme-axis** (private) | the theme *Axis* | `storage/themes/axis-86d2f683-…/` in the web root, www-data | deploy key of www-data |

Your photos, themes, plugins and configuration live in the web root's `storage/`, the
database in `mariadb/`. Neither is part of a repository, so pulling never touches them.

## Server layout: root and www-data

Infrastructure and application are separated on a server:

- **root** owns `/opt/koken/<domain>` (this repository, `.env` with mode `600`, `mariadb/`) and
  Docker. It runs `setup.sh` and `update.sh` and needs no SSH key – this repository is public.
- **www-data** owns the web root `/var/www/htdocs/<domain>` and the deploy keys for the private
  repositories (`/var/www/.ssh`). It has **no** Docker rights and updates Koken and the theme with
  `update-app.sh`, which needs neither Docker nor root.

Only the web root is mounted into the container. An attacker who takes over Koken ends up
there as www-data and reaches neither `.env`, Docker nor the database files. `.git` folders are
never served (`config/apache-koken.conf`). Step by step (German): [INSTALL.md](INSTALL.md).

Locally everything stays in one folder (`src/htdocs`) and belongs to you.

## Updates

```bash
sudo /opt/koken/<domain>/update.sh                     # Docker setup (root)
sudo -u www-data -H /opt/koken/<domain>/update-app.sh /var/www/htdocs/<domain>   # Koken + themes (www-data)
```

Locally: `./update.sh` and `./update-app.sh`.

`update.sh` pulls this repository and rebuilds the containers only when the Docker setup changed.
`update-app.sh` pulls Koken and every theme or plugin folder in `storage/` that is a git checkout,
then clears Koken's caches. PHP picks up code changes immediately (no restart needed).

To change Koken, edit `src/htdocs` locally (a checkout of koken2026-installer), commit and push,
then run `update-app.sh` on every installation.

## Theme Axis (own repository)

The theme in use, *Axis*, is kept in the private repository
[koken-theme-axis](https://github.com/juergenarne/koken-theme-axis) (the Axis license does
not allow redistribution – keep it private). Its folder name must stay as it is: Koken stores
it in the database. Locally and on the server the folder is a checkout of that repository:

```bash
# server (deploy key of www-data, see INSTALL.md step 1)
sudo -u www-data -H git clone git@github-koken-theme-axis:juergenarne/koken-theme-axis.git \
    /var/www/htdocs/<domain>/storage/themes/axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089
```

Edit it locally in `src/htdocs/storage/themes/axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089/`, commit
and push there; `update-app.sh` pulls it on the server. New theme options (e.g. *Frontend → Change
style in frontend*) have to be switched on and published in the admin of each instance – settings
live in the database, not in the theme.

## Local development

```bash
./local-start.sh             # start, import the newest dump from test/dumbs/ if the DB is empty, open the browser
./local-start.sh --fresh-db  # replace the local database with the newest dump
./local-start.sh --stop      # stop (data is kept)
```

Changes in `src/htdocs` are visible immediately (bind mount; the script clears Koken's caches
on every start). With a `storage/` copied from a server, the first start takes the database
credentials for `.env` from `storage/configuration/database.php`.

## Migrating a server with the old layout

Step-by-step guide (German, incl. pitfalls): [MIGRATE.md](MIGRATE.md).

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

**Access to the private Koken repository.** On a server, add a read-only deploy key and
point `KOKEN_REPO` in `.env` to it **before** running the migration (or `setup.sh`):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/koken2026_deploy -N "" -C "koken-server"
cat ~/.ssh/koken2026_deploy.pub      # GitHub: koken2026-installer → Settings → Deploy keys → Add (read only)
cat >> ~/.ssh/config <<'EOF'
Host github-koken2026
    HostName github.com
    User git
    IdentityFile ~/.ssh/koken2026_deploy
    IdentitiesOnly yes
EOF
printf '\nKOKEN_REPO=git@github-koken2026:juergenarne/koken2026-installer.git\n' >> .env
git ls-remote "git@github-koken2026:juergenarne/koken2026-installer.git" master   # test
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
| `config/apache-koken.conf` | Apache settings Koken needs behind a port mapping (see below); blocks `.git` |
| `docker/entrypoint.sh` | Fixes file permissions of `storage/` on container start |
| `setup.sh` | first installation (on a server as root; clones Koken as www-data) |
| `update.sh` | updates the Docker setup (root) |
| `update-app.sh` | updates Koken and git-checked-out themes/plugins, clears the cache (www-data, no Docker) |
| `local-start.sh` | local development copy: start, load dump, open browser |
| `migrate-server.sh` | one-time migration of servers with the old layout |
| `relocate-server.sh` | one-time move of a PHP 8.5 instance to `/opt/koken/<domain>` (root) + `/var/www/htdocs/<domain>` (www-data), see [MIGRATE.md](MIGRATE.md) |
| `src/htdocs/` | Koken itself (locally; on a server `/var/www/htdocs/<domain>`) – checkout of koken2026-installer, **not in this repository** |
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

**Database access from the host.** MariaDB is published on `127.0.0.1:${MYSQL_PORT}` of the
host only (`setup.sh` picks a free port from 3307 on, unique per instance). Locally, connect
your GUI tool or `mysqldump` to `127.0.0.1:<MYSQL_PORT>`; on a server, use the tool's
"connect over SSH" option (or `ssh -N -L <MYSQL_PORT>:127.0.0.1:<MYSQL_PORT> user@server`) with
DB host `127.0.0.1` and port `MYSQL_PORT`. Credentials: `MYSQL_USER`/`MYSQL_PASSWORD` (or
`root`/`MYSQL_ROOT_PASSWORD`) from `.env`.

**Backups** = the web root's `storage/` + a database dump (commands: [INSTALL.md](INSTALL.md), step 7).

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
