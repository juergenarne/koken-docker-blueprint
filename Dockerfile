FROM php:7.4-apache

# Install required system packages and PHP extensions
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libzip-dev \
    libicu-dev \
    libmagickwand-dev \
    imagemagick \
    unzip \
    git \
    mariadb-client \
    --no-install-recommends \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure intl \
    && docker-php-ext-install gd mysqli zip intl exif \
    && if ! pecl list | grep imagick; then pecl install imagick; fi \
    && docker-php-ext-enable imagick \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Enable Apache mod_rewrite for WordPress permalinks
RUN a2enmod rewrite
