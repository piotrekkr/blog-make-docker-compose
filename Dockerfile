#syntax=docker/dockerfile:1

FROM php:8.2.10-cli-bookworm@sha256:750aca14502f934bd3d493a6e57835928d4e6ca1bc093b144670c049dc4b18c8 as base

# disable interactive mode when configuring installed packages
ARG DEBIAN_FRONTEND=noninteractive
# allow running composer as root
ARG COMPOSER_ALLOW_SUPERUSER=1

# set composer directories
ENV COMPOSER_HOME="/.composer"
ENV COMPOSER_CACHE_DIR="/.composer-cache"

# copy composer executable
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# copy php extension installer
COPY --from=mlocati/php-extension-installer:2.1.44 /usr/bin/install-php-extensions /usr/local/bin/

# default architecture
ARG ARCH=amd64

ARG WKHTMLTOX_VERSION=0.12.6.1-3
ARG WKHTMLTOX_DEB=wkhtmltox_${WKHTMLTOX_VERSION}.bookworm_${ARCH}.deb

# change shell so we can use bash arrays
SHELL ["/bin/bash", "-ce"]

RUN <<"EOT"
    apt_install=(
      # required by wkhtmltox
      fontconfig
      libxrender1
      xfonts-base
      xfonts-75dpi
      libxext6
      libjpeg62-turbo
      # other packages
      zip
      unzip
      curl
    )
    php_install=(
      intl
      zip
      pdo
      pdo_pgsql
      pgsql
      dom
      xml
      xmlwriter
      bcmath
      opcache
      pcntl
    )
    apt-get update
    # install all packages from list
    apt-get install -y --no-install-recommends "${apt_install[@]}"
    # install pp extensions using installer
    install-php-extensions "${php_install[@]}"
    mkdir -p "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR"
    # install wkhtmltopdf for selected architecture
    curl --location --silent --show-error --output /tmp/${WKHTMLTOX_DEB} \
      https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/${WKHTMLTOX_DEB}
    dpkg -i  /tmp/${WKHTMLTOX_DEB}
    rm -rf /tmp/${WKHTMLTOX_DEB}
    apt-get autoremove -y
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    # create home and cache directories for composer
    mkdir -p "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR"
EOT

WORKDIR /app

#######
# DEV
#######
FROM base as dev

ENV APP_ENV=dev

# fetch UID/GID from build args
ARG WWW_DATA_UID=1000
ARG WWW_DATA_GID=1000

RUN <<"EOT"
    apt-get update
    # install some additional handy utils
    apt-get install -y --no-install-recommends iputils-ping iproute2 nano
    install-php-extensions xdebug-3.2.0
    # change GID of www-data group
    groupmod -g ${WWW_DATA_GID} www-data
    # change UID of www-data user
    usermod -u ${WWW_DATA_UID} www-data
    # fix ownership of composer home directory and cache
    chown -R www-data:www-data "$COMPOSER_HOME" "$COMPOSER_CACHE_DIR"
EOT

# deafult command for local development and CI
# used just for keeping container running
CMD ["tail", "-f", "/dev/null"]

#######
# CI
#######
FROM dev as ci

ENV APP_ENV=ci

# copy packages configuration
COPY composer.json composer.lock ./

# install all packages including dev packages (required for code style checks, tests etc)
RUN composer install --no-interaction

COPY . .

#######
# PROD
#######

FROM base as prod

ENV APP_ENV=prod

# copy packages configuration
COPY composer.json composer.lock ./

# install all *non dev* packages
RUN composer install --no-interaction --no-dev

COPY . .

# deafult command for production use
# will run application.php without args which should show command help and exit
CMD ["php", "application.php"]