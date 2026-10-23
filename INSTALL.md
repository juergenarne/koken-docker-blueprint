# Neue Koken-Instanz installieren

Vom leeren Verzeichnis zu einer frischen, leeren Koken-Seite mit PHP 8.5, Apache und MariaDB in
Docker. Bestehende Instanzen mit dem alten Aufbau (PHP 7.4) werden nicht neu installiert,
sondern migriert, siehe [MIGRATE.md](MIGRATE.md).

Dauer: etwa 10 Minuten, der größte Teil ist der erste Image-Build.

---

## 0. Voraussetzungen

| | lokal (Mac) | Server (Ubuntu) |
|---|---|---|
| Docker + Docker Compose v2 | Docker Desktop | `docker.io` + `docker-compose-v2` (oder Docker CE) |
| git, curl | ✓ | ✓ |
| Zugriff auf das **private** Repo `koken2026-installer` | dein GitHub-SSH-Schlüssel | Deploy-Key (Schritt 1) |
| Reverse Proxy mit HTTPS | – | nginx + certbot (Schritt 4) |

Der Linux-Benutzer muss Docker benutzen dürfen. Das prüfst du mit `docker ps`. Falls nötig:
`sudo usermod -aG docker <benutzer>`, danach neu anmelden.

---

## 1. Zugriff auf `koken2026-installer` (nur Server, einmal pro Server)

Lokal brauchst du diesen Schritt nicht, dort greift dein normaler GitHub-SSH-Schlüssel.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/koken2026_deploy -N "" -C "koken-$(hostname)"
cat ~/.ssh/koken2026_deploy.pub
```

Den Schlüssel auf GitHub eintragen: **koken2026-installer → Settings → Deploy keys → Add deploy key**.
„Allow write access“ **nicht** anhaken.

```bash
cat >> ~/.ssh/config <<'EOF'
Host github-koken2026
    HostName github.com
    User git
    IdentityFile ~/.ssh/koken2026_deploy
    IdentitiesOnly yes
EOF

git ls-remote git@github-koken2026:juergenarne/koken2026-installer.git master   # muss eine Zeile zeigen
```

Gibt es auf dem Server schon eine Instanz, existieren Schlüssel und `~/.ssh/config` bereits.
Dann diesen Schritt überspringen.

---

## 2. Docker-Repo klonen und `.env` anlegen

Statt `<instanz>` einen Namen einsetzen, zum Beispiel die Domain:

```bash
cd /var/www/htdocs                      # lokal: ein beliebiger Ordner
git clone git@github.com:juergenarne/koken-docker-blueprint.git <instanz>
cd <instanz>
cp .env.dist .env
chmod 600 .env
```

In der `.env` anpassen. Passwörter und Installer-Token **leer lassen**, die erzeugt `setup.sh`.

| Variable | Bedeutung | Beispiel |
|---|---|---|
| `APP_NAME` | Präfix der Container (`<APP_NAME>-apache`, `<APP_NAME>-mariadb`). **Pro Instanz auf einem Server eindeutig!** | `urbanphotography.berlin` |
| `APACHE_PORT` | Port auf dem Host. **Pro Instanz eindeutig.** | `8085` |
| `APACHE_BIND` | `127.0.0.1` hinter nginx oder lokal; `0.0.0.0` nur, wenn der Container direkt von außen erreichbar sein soll | `127.0.0.1` |
| `TZ` | Zeitzone | `Europe/Berlin` |
| `KOKEN_REPO` | Server: die Adresse mit dem Deploy-Key-Alias aus Schritt 1 | `git@github-koken2026:juergenarne/koken2026-installer.git` |
| `MYSQL_DATABASE`, `MYSQL_USER` | Name der Datenbank und des DB-Benutzers | `koken` |
| `INSTALL_FFMPEG` | `true` für Video-Unterstützung (größeres Image) | `false` |

Lokal kann `KOKEN_REPO` auf dem Standardwert `git@github.com:…` bleiben.

---

## 3. `setup.sh` ausführen

```bash
./setup.sh -y           # ohne Rückfragen; ohne -y fragt es nach dem Port
```

Das Skript:

1. trägt zufällige DB-Passwörter und ein **Installer-Token** in `.env` ein,
2. klont `koken2026-installer` nach `src/htdocs`,
3. baut das PHP-8.5-Image und startet die Container. Beim ersten Mal dauert das einige Minuten.
4. Am Ende gibt es den Link zum Installer aus:

```
Done. Open the installer to finish the setup in your browser:

    http://localhost:8085/install/?token=Ab3…
```

Lokal kannst du diesen Link direkt öffnen, weiter mit **Schritt 5**.
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

```bash
docker ps                                   # <APP_NAME>-apache und <APP_NAME>-mariadb laufen
docker exec <APP_NAME>-apache php -v        # PHP 8.5.x
git status && git -C src/htdocs status      # beide: nothing to commit
```

---

## 7. Betrieb

**Updates** von Koken-Code oder Docker-Setup:

```bash
./update.sh
```

**Backup:**

```bash
docker exec <APP_NAME>-mariadb sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction "$MARIADB_DATABASE"' | gzip > koken-db-$(date +%F).sql.gz
tar -czf koken-storage-$(date +%F).tar.gz --exclude=./storage/cache -C src/htdocs ./storage
```

| Was | Wo | Im Git? |
|---|---|---|
| Bilder, Themes, Plugins, Konfiguration | `src/htdocs/storage/` | nein |
| Datenbank | `mariadb/` | nein |
| Passwörter, Ports, Token | `.env` | nein |
| Koken-Code | `src/htdocs` (Repo `koken2026-installer`) | ja |
| Docker-Setup | dieses Repo | ja |

**Themes und Plugins:** Den Koken-Store gibt es nicht mehr. Themes kopierst du nach
`src/htdocs/storage/themes/`, Plugins nach `src/htdocs/storage/plugins/`. Danach erscheinen sie in
der Admin-Konsole.

**Mehrere Instanzen auf einem Server:** Jede bekommt ihr eigenes Verzeichnis, einen eigenen
`APP_NAME`, einen eigenen `APACHE_PORT` und einen eigenen nginx-`server`-Block. Der Deploy-Key aus
Schritt 1 wird gemeinsam genutzt.

---

## Wenn etwas hakt

| Problem | Lösung |
|---|---|
| `setup.sh`: *Cannot clone …* / *Permission denied (publickey)* | Deploy-Key (Schritt 1) und `KOKEN_REPO` in `.env` prüfen; Test mit `git ls-remote` |
| `setup.sh`: *port is already allocated* | `APACHE_PORT` ist belegt. Anderen Port in `.env` eintragen und `./setup.sh` noch einmal ausführen |
| Installer zeigt *Installer locked* | Link ohne oder mit falschem Token geöffnet. Token steht in `.env` (`KOKEN_INSTALL_TOKEN`) |
| Installer: *Loopback HTTP requests – Error* | Der Server erreicht sich nicht selbst über die Domain. DNS/nginx prüfen (Schritt 4, `curl`-Test) |
| Installer: *storage/ writable – Error* | `docker compose restart web` (der Container korrigiert die Rechte beim Start) |
| Installer: *Koken install routine present – Error* | Koken wurde schon einmal installiert und hat die Datei gelöscht: `git -C src/htdocs checkout -- app/application/controllers/install.php` |
| Seite leer / *API Error* nach der Installation | Logs ansehen: `docker compose logs web`. Prüfen, ob in `src/htdocs/storage/configuration/user_setup.php` hinter nginx/HTTPS ein `LOOPBACK_HOST_HEADER` steht; der gehört dort nicht hin |
| Komplett von vorn | `docker compose down`, dann `src/htdocs/storage/` und `mariadb/` löschen (**alle Daten weg!**), danach `./setup.sh` |
