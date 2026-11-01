#!/bin/sh
# Make sure Apache (www-data) can write where Koken needs to write:
#   storage/                                  images, cache, themes, plugins, configuration
#   .htaccess                                 pretty URL rules (written by the installer/settings)
#   app/application/controllers/install.php   deleted after the installation
set -e

ROOT=/var/www/html

mkdir -p "$ROOT/storage"

# Only walk the (possibly large) storage tree when something is not owned by www-data.
# On a server the web root belongs to www-data anyway (same UID 33 as on Debian/Ubuntu
# hosts), so this does nothing there. git checkouts of themes/plugins (.git) are skipped:
# Apache never needs them, and Docker Desktop refuses to chown their read-only objects.
if [ -n "$(find "$ROOT/storage" -name .git -prune -o ! -user www-data -print -quit 2>/dev/null)" ]; then
    echo "koken: fixing ownership of storage/ (first start or files added from the host)"
    find "$ROOT/storage" -name .git -prune -o ! -user www-data -exec chown www-data:www-data {} + \
        || echo "koken: warning: could not change the owner of some files in storage/"
fi

[ -f "$ROOT/.htaccess" ] && chown www-data:www-data "$ROOT/.htaccess"
chown www-data:www-data "$ROOT" "$ROOT/app/application/controllers" 2>/dev/null || true

# Also listen on the host port of the port mapping, so Koken's internal requests to
# http://<host>:<port>/ from inside the container work (see config/apache-koken.conf)
if [ -n "${KOKEN_PUBLIC_PORT:-}" ] && [ "$KOKEN_PUBLIC_PORT" != 80 ] && ! grep -q "^Listen $KOKEN_PUBLIC_PORT\$" /etc/apache2/ports.conf; then
    echo "Listen $KOKEN_PUBLIC_PORT" >> /etc/apache2/ports.conf
fi

# Outgoing mail (password reset): PHP's mail() calls /usr/sbin/sendmail, which is msmtp
# when SMTP_HOST is set. Without it there is no sendmail, so Koken reports that email
# delivery is not configured instead of failing silently.
if [ -n "${SMTP_HOST:-}" ]; then
    port=${SMTP_PORT:-587}
    {
        echo "defaults"
        # 465 = TLS from the start, otherwise (587, 25) STARTTLS; SMTP_TLS=off for local test servers
        if [ "${SMTP_TLS:-}" = off ]; then
            echo "tls off"
        else
            echo "tls on"
            [ "$port" = 465 ] && echo "tls_starttls off" || echo "tls_starttls on"
        fi
        echo "tls_trust_file /etc/ssl/certs/ca-certificates.crt"
        echo "account default"
        echo "host $SMTP_HOST"
        echo "port $port"
        # Koken sends from the user's own address; the server only accepts its own
        echo "from ${SMTP_FROM:-${SMTP_USER:-}}"
        echo "set_from_header on"
        echo "allow_from_override off"
        if [ -n "${SMTP_USER:-}" ]; then
            echo "auth on"
            echo "user $SMTP_USER"
            echo "password $SMTP_PASSWORD"
        fi
    } > /etc/msmtprc
    chown root:www-data /etc/msmtprc
    chmod 640 /etc/msmtprc
    ln -sf /usr/bin/msmtp /usr/sbin/sendmail
else
    rm -f /usr/sbin/sendmail /etc/msmtprc
fi

exec docker-php-entrypoint "$@"
