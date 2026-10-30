# Neue Koken-Instanz installieren

Vom leeren Server (oder Ordner) zu einer frischen, leeren Koken-Seite mit PHP 8.5, Apache und MariaDB in
Docker. Bestehende Instanzen mit dem alten Aufbau (PHP 7.4) werden nicht neu installiert,
sondern migriert, siehe [MIGRATE.md](MIGRATE.md).

Dauer: etwa 10 Minuten, der größte Teil ist der erste Image-Build.

---

## 0. Voraussetzungen

| | lokal (Mac) | Server (Ubuntu) |
|---|---|---|
| Docker + Docker Compose v2 | Docker Desktop | `docker.io` + `docker-compose-v2` (oder Docker CE) |
| git, curl | ✓ | ✓ (dazu `sudo`) |
| Zugriff auf die **privaten** Repos `koken2026-installer`, `koken-theme-axis` | dein GitHub-SSH-Schlüssel | Deploy-Keys von `www-data` (Schritt 1) |
| Reverse Proxy mit HTTPS | – | nginx + certbot (Schritt 4) |

**Lokal** arbeitest du als normaler Benutzer. Er muss Docker benutzen dürfen (`docker ps`).
Alles liegt in einem Ordner, Koken in `src/htdocs`.

**Auf dem Server** sind Infrastruktur und Anwendung getrennt:

| | root | www-data |
|---|---|---|
| Verzeichnis | `/opt/koken/<domain>`: dieses Repo, `.env` (`600`), `mariadb/` | `/var/www/htdocs/<domain>`: Koken mit `storage/` (Bilder, Themes, Konfiguration) |
| zuständig für | Docker, PHP, Datenbank: `setup.sh`, `update.sh` | die Anwendung: `update-app.sh` (Koken + Themes) |
| Docker-Rechte | ja | **nein** |
| SSH-Schlüssel | **keine**: dieses Repo ist öffentlich und kommt über https | Deploy-Keys für `koken2026-installer` und `koken-theme-axis` in `/var/www/.ssh` |

Nur `/var/www/htdocs/<domain>` ist im Container sichtbar. Wer die Website angreift, landet dort
als `www-data` und kommt weder an `.env` noch an Docker oder die Datenbankdateien.

Du arbeitest als dein Admin-Benutzer: `sudo …` für root, `sudo -u www-data -H …` für `www-data`.
Der Admin-Benutzer muss nicht in der Gruppe `docker` sein.

---

## 1. Deploy-Keys für `www-data` (nur Server, einmal pro Server)

Lokal brauchst du diesen Schritt nicht, dort greift dein normaler GitHub-SSH-Schlüssel.

Die Schlüssel gehören `www-data` und liegen in seinem Home-Verzeichnis `/var/www` (außerhalb jedes
Web-Roots). GitHub erlaubt einen Deploy-Key pro Repo, deshalb zwei:

```bash
sudo install -d -m 700 -o www-data -g www-data /var/www/.ssh
sudo -u www-data -H ssh-keygen -t ed25519 -f /var/www/.ssh/koken2026_deploy -N "" -C "koken2026 $(hostname)"
sudo -u www-data -H ssh-keygen -t ed25519 -f /var/www/.ssh/koken_theme_axis_deploy -N "" -C "koken-theme-axis $(hostname)"
cat /var/www/.ssh/koken2026_deploy.pub /var/www/.ssh/koken_theme_axis_deploy.pub
```

Die beiden Schlüssel auf GitHub eintragen, jeweils **Settings → Deploy keys → Add deploy key**,
„Allow write access“ **nicht** anhaken:

- `koken2026_deploy.pub` → `koken2026-installer`
- `koken_theme_axis_deploy.pub` → `koken-theme-axis`

```bash
sudo -u www-data -H tee -a /var/www/.ssh/config >/dev/null <<'EOF'
Host github-koken2026
    HostName github.com
    User git
    IdentityFile ~/.ssh/koken2026_deploy
    IdentitiesOnly yes

Host github-koken-theme-axis
    HostName github.com
    User git
    IdentityFile ~/.ssh/koken_theme_axis_deploy
    IdentitiesOnly yes
EOF
ssh-keyscan -t ed25519 github.com 2>/dev/null | sudo -u www-data -H tee -a /var/www/.ssh/known_hosts >/dev/null

# beide müssen eine Zeile zeigen
sudo -u www-data -H git ls-remote git@github-koken2026:juergenarne/koken2026-installer.git master
sudo -u www-data -H git ls-remote git@github-koken-theme-axis:juergenarne/koken-theme-axis.git master
```

Gibt es auf dem Server schon eine Instanz, existieren Schlüssel und Config bereits. Dann diesen
Schritt überspringen.

---

## 2. Docker-Repo klonen und `.env` anlegen

Server (als root, Verzeichnis `755`: es enthält nur, was ohnehin öffentlich ist):

```bash
sudo git clone https://github.com/juergenarne/koken-docker-blueprint.git /opt/koken/<domain>
cd /opt/koken/<domain>
sudo cp .env.dist .env && sudo chmod 600 .env
sudo nano .env
```

Lokal:

```bash
git clone https://github.com/juergenarne/koken-docker-blueprint.git koken
cd koken
cp .env.dist .env && chmod 600 .env
```

In der `.env` anpassen. Passwörter und Installer-Token **leer lassen**, die erzeugt `setup.sh`.

| Variable | Bedeutung | Beispiel |
|---|---|---|
| `APP_NAME` | Präfix der Container (`<APP_NAME>-apache`, `<APP_NAME>-mariadb`). **Pro Instanz auf einem Server eindeutig!** | `urbanphotography.berlin` |
| `APACHE_PORT` | Port auf dem Host. **Pro Instanz eindeutig.** | `8085` |
| `APACHE_BIND` | `127.0.0.1` hinter nginx oder lokal; `0.0.0.0` nur, wenn der Container direkt von außen erreichbar sein soll | `127.0.0.1` |
| `APACHE_HTDOCS` | Web-Root (Koken). Server: **absoluter Pfad** unter `/var/www/htdocs`; lokal `./src/htdocs` | `/var/www/htdocs/urbanphotography.berlin` |
| `TZ` | Zeitzone | `Europe/Berlin` |
| `KOKEN_REPO` | Server: die Adresse mit dem Deploy-Key-Alias aus Schritt 1 | `git@github-koken2026:juergenarne/koken2026-installer.git` |
| `MYSQL_DATABASE`, `MYSQL_USER` | Name der Datenbank und des DB-Benutzers | `koken` |
| `INSTALL_FFMPEG` | `true` für Video-Unterstützung (größeres Image) | `false` |

Lokal können `APACHE_HTDOCS` und `KOKEN_REPO` auf den Standardwerten bleiben.

---

## 3. `setup.sh` ausführen

```bash
sudo ./setup.sh -y      # Server; lokal: ./setup.sh -y  (ohne -y fragt es nach dem Port)
```

Das Skript:

1. trägt zufällige DB-Passwörter und ein **Installer-Token** in `.env` ein (`600`),
2. klont `koken2026-installer` nach `APACHE_HTDOCS`. Auf dem Server legt es das Verzeichnis für
   `www-data` an und klont **als `www-data`** mit dessen Deploy-Key. root selbst hat keinen Schlüssel.
3. baut das PHP-8.5-Image und startet die Container. Beim ersten Mal dauert das einige Minuten.
4. Am Ende gibt es den Link zum Installer und die Update-Befehle aus:

```
Done. Open the installer to finish the setup in your browser:

    http://localhost:8085/install/?token=Ab3…

Updates:  Docker setup  sudo /opt/koken/<domain>/update.sh
          Koken         sudo -u www-data -H /opt/koken/<domain>/update-app.sh /var/www/htdocs/<domain>
```

Lokal kannst du den Link direkt öffnen, weiter mit **Schritt 5**.
Auf dem Server richtest du zuerst nginx ein (Schritt 4) und ersetzt dann `http://localhost:<port>`
durch `https://<domain>`. Den Token findest du jederzeit in der `.env` unter `KOKEN_INSTALL_TOKEN`.

---

## 4. nginx und HTTPS (nur Server)

`/etc/nginx/sites-available/<domain>`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name <domain>;

    client_max_body_size 80M;            # Bild-Uploads (passt zu upload_max_filesize in config/php.ini)

    location / {
        proxy_pass http://127.0.0.1:<APACHE_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect http://$host/ https://$host/;
        proxy_read_timeout 300;          # große Uploads / Bildberechnung
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/<domain> /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d <domain>     # Zertifikat + Umleitung http → https
```

Wichtig:

- `proxy_set_header Host $host` ist Pflicht. Koken baut daraus seine Links und ruft sich darüber
  selbst auf.
- Die Domain muss **vom Server selbst** erreichbar sein, denn Koken ruft seine eigene API über
  `https://<domain>/` auf. Das testest du auf dem Server mit
  `curl -sI https://<domain>/install/index.php?ping=1`, die Antwort muss `200` sein.

---

## 5. Installer im Browser

Den Link mit Token öffnen: `https://<domain>/install/?token=…` (lokal: `http://localhost:<port>/install/?token=…`).

1. **Voraussetzungen.** Alles muss auf *OK* stehen. Bei *Loopback HTTP requests* steht hinter nginx
   `direct`.
2. **Datenbank.** *„Use the database prepared by Docker“* ist vorausgewählt. Einfach weiter.
3. **Dein Konto.** Vor- und Nachname, E-Mail (= Login), Passwort (mindestens 8 Zeichen), Zeitzone.
   Dein Name wird zum vorläufigen Seitentitel. Dann **Install Koken**.
4. **Fertig.** Danach ist der Installer gesperrt.

Anmelden unter `https://<domain>/admin/`. Dort stellst du Seitentitel, Theme und alles Weitere ein.

---

## 6. Prüfen

- `https://<domain>/` zeigt die leere Seite im Theme *Elementary*.
- `https://<domain>/admin` leitet auf `https://<domain>/admin/` weiter (**nicht** auf `localhost`).
- In der Admin-Konsole ein Bild hochladen. Es muss auf der Seite in allen Größen erscheinen.

Auf dem Server, im Verzeichnis `/opt/koken/<domain>` (lokal ohne `sudo`, Web-Root `src/htdocs`):

```bash
sudo docker ps                                    # <APP_NAME>-apache und <APP_NAME>-mariadb laufen
sudo docker exec <APP_NAME>-apache php -v         # PHP 8.5.x
sudo git status                                   # nothing to commit
sudo -u www-data -H git -C /var/www/htdocs/<domain> status          # nothing to commit
curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/.git/config   # 404
ls -la .env /var/www/htdocs/<domain>              # .env: root, -rw-------; Web-Root: www-data
```

---

## 7. Betrieb

**Updates** – zwei getrennte Wege:

```bash
# Docker-Setup (PHP, Apache, MariaDB) – root, holt dieses Repo über https
sudo /opt/koken/<domain>/update.sh

# Anwendung (Koken + Themes/Plugins, die Git-Checkouts sind) – www-data, ohne Docker
sudo -u www-data -H /opt/koken/<domain>/update-app.sh /var/www/htdocs/<domain>
```

Lokal: `./update.sh` und `./update-app.sh` (ohne Argument, der Web-Root kommt aus der `.env`).
`update-app.sh` leert danach Kokens Cache. PHP sieht Code-Änderungen sofort, ein Neustart ist
nicht nötig.

**Theme Axis** als Git-Checkout, damit `update-app.sh` es mit aktualisiert. Der Ordnername muss
genau so bleiben, Koken speichert ihn in der Datenbank:

```bash
sudo -u www-data -H git clone git@github-koken-theme-axis:juergenarne/koken-theme-axis.git \
    /var/www/htdocs/<domain>/storage/themes/axis-86d2f683-9f90-ca3f-d93f-a2e0a9d0a089
```

Danach in der Admin-Konsole unter *Themes* auswählen. `storage/` legt der Installer an, also erst nach
Schritt 5.

**Backup** (Server, als root):

```bash
cd /opt/koken/<domain>
sudo docker exec <APP_NAME>-mariadb sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE"' | gzip > koken-db-$(date +%F).sql.gz
sudo tar -czf koken-storage-$(date +%F).tar.gz --exclude=./storage/cache -C /var/www/htdocs/<domain> ./storage
```

| Was | Server | lokal | Im Git? |
|---|---|---|---|
| Bilder, Themes, Plugins, Konfiguration | `/var/www/htdocs/<domain>/storage/` (www-data) | `src/htdocs/storage/` | nein (Themes: eigene Repos) |
| Koken-Code | `/var/www/htdocs/<domain>` (www-data) | `src/htdocs` | ja, `koken2026-installer` |
| Datenbank | `/opt/koken/<domain>/mariadb/` (MariaDB, UID 999) | `mariadb/` | nein |
| Passwörter, Ports, Token | `/opt/koken/<domain>/.env` (root, `600`) | `.env` | nein |
| Docker-Setup | `/opt/koken/<domain>` (root) | Repo-Ordner | ja, dieses Repo |

**Andere Themes und Plugins:** Den Koken-Store gibt es nicht mehr. Themes kopierst du (als `www-data`)
nach `storage/themes/`, Plugins nach `storage/plugins/`. Danach erscheinen sie in der Admin-Konsole.

**Mehrere Instanzen auf einem Server:** Jede bekommt ihr eigenes `/opt/koken/<domain>` und
`/var/www/htdocs/<domain>`, einen eigenen `APP_NAME`, einen eigenen `APACHE_PORT` und einen eigenen
nginx-`server`-Block. Die Deploy-Keys aus Schritt 1 werden gemeinsam genutzt.

---

## Wenn etwas hakt

`<web-root>` ist auf dem Server `/var/www/htdocs/<domain>`, lokal `src/htdocs`.

| Problem | Lösung |
|---|---|
| `setup.sh`: *Cannot clone …* / *Permission denied (publickey)* | Deploy-Key von `www-data` (Schritt 1) und `KOKEN_REPO` in `.env` prüfen; Test: `sudo -u www-data -H git ls-remote <KOKEN_REPO> master` |
| `setup.sh`: *APACHE_HTDOCS … must be the absolute path* | Auf dem Server `APACHE_HTDOCS=/var/www/htdocs/<domain>` in die `.env` eintragen |
| `setup.sh`: *… does not belong to www-data* | `sudo chown -R www-data:www-data /var/www/htdocs/<domain>` |
| `update-app.sh`: *Do not run this as root* / *No write access* | Als Besitzer des Web-Roots aufrufen: `sudo -u www-data -H …/update-app.sh /var/www/htdocs/<domain>` |
| `update-app.sh`: *Usage: … <web root>* | Den Web-Root als Argument angeben; `www-data` darf die `.env` nicht lesen |
| `setup.sh`: *port is already allocated* | `APACHE_PORT` ist belegt. Anderen Port in `.env` eintragen und `setup.sh` noch einmal ausführen |
| Installer zeigt *Installer locked* | Link ohne oder mit falschem Token geöffnet. Token steht in `.env` (`KOKEN_INSTALL_TOKEN`) |
| Installer: *Loopback HTTP requests – Error* | Der Server erreicht sich nicht selbst über die Domain. DNS/nginx prüfen (Schritt 4, `curl`-Test) |
| Installer: *storage/ writable – Error* | `sudo docker compose restart web` (der Container korrigiert die Rechte beim Start) |
| Installer: *Koken install routine present – Error* | Koken wurde schon einmal installiert und hat die Datei gelöscht: `sudo -u www-data -H git -C <web-root> checkout -- app/application/controllers/install.php` |
| Seite leer / *API Error* nach der Installation | Logs ansehen: `sudo docker compose logs web`. Prüfen, ob in `<web-root>/storage/configuration/user_setup.php` hinter nginx/HTTPS ein `LOOPBACK_HOST_HEADER` steht; der gehört dort nicht hin |
| Komplett von vorn | `docker compose down`, dann `<web-root>/storage/` und `mariadb/` löschen (**alle Daten weg!**), danach `setup.sh` |
