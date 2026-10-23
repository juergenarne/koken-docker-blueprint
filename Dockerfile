# PHP 8.5.x (latest patch release). Override with --build-arg PHP_VERSION=...
ARG PHP_VERSION=8.5.12
FROM php:${PHP_VERSION}-apache

# Optional video support (Koken uses ffmpeg for video thumbnails): --build-arg INSTALL_FFMPEG=true
ARG INSTALL_FFMPEG=false

# System packages and PHP extensions needed by Koken
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libmagickwand-dev \
    imagemagick \
    unzip \
    mariadb-client \
    --no-install-recommends \
    && if [ "$INSTALL_FFMPEG" = "true" ]; then apt-get install -y --no-install-recommends ffmpeg; fi \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd mysqli pdo_mysql zip intl exif \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/pear

# Pretty URLs (.htaccess) and Koken's loopback requests behind port mappings
RUN a2enmod rewrite
COPY config/apache-koken.conf /etc/apache2/conf-enabled/koken.conf

# Fixes permissions of the mounted Koken directory, then starts Apache
COPY docker/entrypoint.sh /usr/local/bin/koken-entrypoint
RUN chmod +x /usr/local/bin/koken-entrypoint
ENTRYPOINT ["koken-entrypoint"]
CMD ["apache2-foreground"]
