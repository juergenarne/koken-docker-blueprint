# Migration einer Koken-Instanz von PHP 7.4 auf PHP 8.5

Diese Anleitung gilt für Instanzen im **alten Aufbau**:

- Das Verzeichnis ist ein Klon von `koken-docker-blueprint` (alter `master`, PHP 7.4).
- Der Koken-Code liegt **unversioniert** in `src/htdocs` (von Hand hineinkopiert).
- `.env` und `src/htdocs/index.php` sind im Repo versioniert und auf dem Server lokal geändert.

Nach der Migration ist `src/htdocs` ein Klon von `koken2026-installer`, das Docker-Setup läuft
mit PHP 8.5, und Updates gehen mit `./update.sh`. **Bilder (`src/htdocs/storage`) und Datenbank
werden nicht verändert.** Eine Datenbank-Migration ist nicht nötig.

> **Nie auf einer alten Instanz einfach `git pull` machen.** Git bricht ab, und die naheliegenden
> „Lösungen“ (`git stash -u`, `git clean -fd`, `git checkout -f`) können `src/htdocs/storage`
> und `mariadb/` löschen. Immer `migrate-server.sh` benutzen.

Dauer: etwa 15 Minuten, davon wenige **Sekunden** Ausfall der Seite.

---

## 0. Voraussetzungen prüfen

Auf dem Server, im Verzeichnis der Instanz (Beispiel: `/var/www/htdocs/subway.berlin`):

```bash
cd /var/www/htdocs/<instanz>
docker ps                         # der Benutzer muss docker benutzen dürfen
git status
git log origin/master..master     # muss leer sein (keine eigenen Commits)
```

Bei `git status` dürfen nur diese beiden Dateien als geändert erscheinen:

```
modified:   .env
modified:   src/htdocs/index.php
```

Dazu kommen untracked `mariadb/`, `src/htdocs/storage/` und die Koken-Dateien. Das ist normal.

**Ist noch eine andere Datei geändert** (bei subway.berlin war es `docker-compose.yml`), sieh
dir die Änderung an:

```bash
git diff docker-compose.yml       # NICHT git diff .env posten – da stehen Passwörter drin
```

- **Die Änderung gibt es schon als Commit auf GitHub.** Bei subway.berlin war `restart: always`
  identisch mit Commit `e614cbe`. Dann den Server auf diesen Commit bringen:
  ```bash
  git checkout -- docker-compose.yml
  git merge --ff-only e614cbe       # Commit-Hash anpassen
  ```
- **Die Änderung ist instanzspezifisch** (z. B. ein anderer Port oder ein zusätzliches Volume).
  Dann gehört sie nach der Migration in die `.env` (Ports, Namen) oder in eine
  `docker-compose.override.yml`. Vorher notieren und die Datei mit `git checkout -- <datei>`
  zurücksetzen.

Danach darf `git status` wieder nur `.env` und `src/htdocs/index.php` zeigen.

---

## 1. Fallback-Branch sichern

Der aktuelle Stand des Docker-Setups wird als Branch auf GitHub gesichert, **ohne ihn
auszuchecken**:

```bash
git branch feature/php7-<instanz> master
git push origin feature/php7-<instanz>
```

Den Branch auf dem Server **nicht** auschecken und nichts darauf committen.

Er enthält nur die versionierten Dateien. `.env`, Koken-Code, Bilder und Datenbank sichert
`migrate-server.sh` im nächsten Schritt in ein eigenes Backup-Verzeichnis. Dort landet auch
das alte PHP-7.4-Image als `koken-rollback:<datum>`. Das alte Dockerfile lässt sich nicht mehr
bauen (Debian 11 ist EOL), deshalb ist dieses Image der eigentliche Fallback.

---

## 2. Zugriff auf das private Repo `koken2026-installer`

Einmal pro **Server** und Linux-Benutzer. Liegen mehrere Instanzen auf demselben Server,
nutzen sie denselben Schlüssel, dann diesen Schritt überspringen und nur `KOKEN_REPO` in
die `.env` eintragen (letzter Befehl).

```bash
ssh-keygen -t ed25519 -f ~/.ssh/koken2026_deploy -N "" -C "koken-$(hostname)"
cat ~/.ssh/koken2026_deploy.pub
```

Den ausgegebenen Schlüssel auf GitHub eintragen: **koken2026-installer → Settings → Deploy keys
→ Add deploy key**. „Allow write access“ **nicht** anhaken. Ein Deploy-Key gilt nur für ein Repo
und kann nicht zweimal hinzugefügt werden, daher pro Server einen eigenen anlegen.

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

In die `.env` der Instanz eintragen, mit `printf`, weil die alte `.env` oft ohne
Zeilenumbruch endet:

```bash
printf '\nKOKEN_REPO=git@github-koken2026:juergenarne/koken2026-installer.git\n' >> .env
```

---

## 3. Trockenlauf

Das Skript gibt es nur in der neuen Version des Repos. Es wird deshalb geholt, ohne zu
pullen. Statt `<domain>` die Domain der Instanz einsetzen (z. B. `urbanphotography.berlin`):

```bash
git fetch origin
git show origin/master:migrate-server.sh > /tmp/migrate-server.sh
bash /tmp/migrate-server.sh --host <domain> 2>&1 | tee /tmp/migrate-dryrun.txt
```

Der Trockenlauf ändert nichts. Darauf achten:

| Abschnitt | erwartet |
|---|---|
| 1. Checks | richtiges Verzeichnis, Container `<APP_NAME>-apache` / `-mariadb`, Port aus der `.env` |
| Fetching | `Koken code: git@github-koken2026:…` mit Commit-Hash (sonst stimmt Schritt 2 nicht) |
| 2. Local changes | `no modified Koken files` oder eine **kurze** Liste mit Dateien, die du wirklich angepasst hast. Diese Dateien werden ersetzt, eine Kopie kommt ins Backup. |
| Disk space | genug Platz für das Backup |
| Ende | `Dry run finished – nothing was changed.` |

Bricht das Skript mit `Local changes in versioned files` ab, zurück zu Schritt 0.

---

## 4. Migration

```bash
bash /tmp/migrate-server.sh --host <domain> --apply 2>&1 | tee /tmp/migrate-apply.txt
```

Das Skript macht dabei Folgendes:

1. **Backup** nach `../koken-backup-<datum>/`: DB-Dump, `storage` (ohne Cache), alter Code, `.env`,
   `rollback.sh`; das alte Image wird getaggt.
2. **Docker-Repo aktualisieren.** `.env` und `index.php` bleiben erhalten, am Ende steht
   `master` genau auf `origin/master`.
3. **Image bauen.** Das dauert einige Minuten, die Seite läuft währenddessen unverändert weiter.
4. **Umschalten:** `src/htdocs` wird zum Klon von `koken2026-installer`, die Container werden
   neu gestartet. Das dauert wenige Sekunden.
5. **Prüfen:** Die Startseite muss mit HTTP 200 antworten.

Am Ende steht `Done.` und eine Zeile mit `PHP 8.5.x`.

---

## 5. Prüfen

Im Browser:

- `https://<domain>/` – Startseite, ein Album, ein einzelnes Bild
- `https://<domain>/admin` – muss auf `https://<domain>/admin/` weiterleiten (**nicht** auf `localhost`)
- in der Admin-Konsole anmelden und z. B. einen Bildtitel ändern und speichern

Auf dem Server:

```bash
git status                     # nothing to commit
git -C src/htdocs status       # nothing to commit
docker exec <APP_NAME>-apache php -v
```

---

## 6. nginx (Reverse Proxy) – einmalig, optional

Apache im Container kennt HTTPS nicht. Weiterleitungen wie `/admin` → `/admin/` gehen deshalb
erst auf `http://` und dann über nginx auf `https://`. Das funktioniert, mit dieser Zeile im
`location /`-Block geht es aber direkt:

```nginx
proxy_redirect http://$host/ https://$host/;
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Außerdem gilt:

- Der Web-Port ist jetzt nur an `127.0.0.1` gebunden (`APACHE_BIND` in `.env`). nginx muss also
  auf `proxy_pass http://127.0.0.1:<APACHE_PORT>;` zeigen.
- In `src/htdocs/storage/configuration/user_setup.php` darf hinter nginx/HTTPS **kein**
  `define('LOOPBACK_HOST_HEADER', true);` stehen. Das Skript warnt, falls doch.

---

## 7. Falls etwas nicht stimmt: Rollback

```bash
bash ../koken-backup-<datum>/rollback.sh
```

Das stellt Docker-Setup, `.env`, den alten Koken-Code und das PHP-7.4-Image wieder her. Bilder
und Datenbank hat die Migration nicht verändert. Für den Notfall liegen sie trotzdem im Backup
(`storage.tar.gz`, `database.sql.gz`).

---

## 8. Danach

**Updates** (Koken-Code oder Docker-Setup):

```bash
./update.sh
```

Das Skript holt beide Repos, baut die Container nur neu, wenn sich am Docker-Setup etwas
geändert hat, und leert Kokens Cache.

**Aufräumen**, wenn alles ein paar Tage gut läuft:

```bash
rm -rf ../koken-backup-<datum>
docker rmi koken-rollback:<datum>
```

---

## Stolperstellen von der ersten Migration (subway.berlin)

| Symptom | Ursache | Stand |
|---|---|---|
| Trockenlauf meldet *jede* Koken-Datei als geändert (836 Stück) | andere Dateirechte (z. B. 755) | behoben, das Skript vergleicht nur noch den Inhalt |
| `docker-compose.yml` lokal geändert | Änderung direkt auf dem Server gemacht, nie gepullt | wird im Trockenlauf erkannt → Schritt 0 |
| `/admin` leitete auf `https://localhost/admin/` | Apache-Konfiguration (`UseCanonicalName`) | behoben |
| `update.sh` scheiterte nach der Migration | Hilfs-Commits der Migration | behoben, das Skript endet auf `origin/master`, `update.sh` räumt solche Commits auf |

Instanzen, die **nicht** als Git-Klon von `koken-docker-blueprint` aufgesetzt wurden, kann das
Skript nicht migrieren. Dann daneben neu aufsetzen:

1. `git clone` von `koken-docker-blueprint`, `.env` aus `.env.dist` anlegen. Die DB-Zugangsdaten
   (`MYSQL_*`) übernimmst du aus der alten Instanz, sie müssen zu
   `storage/configuration/database.php` passen.
2. Die alte Instanz stoppen. Dann **vor** `./setup.sh` ihr `src/htdocs/storage/` nach
   `src/htdocs/storage/` und ihr MariaDB-Datenverzeichnis nach `mariadb/data/lib/` kopieren.
3. `./setup.sh` ausführen. Es klont Koken neben das vorhandene `storage/` und startet die
   Container. Der Installer bleibt gesperrt, weil die Installation schon existiert.
