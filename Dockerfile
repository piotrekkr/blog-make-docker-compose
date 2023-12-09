#syntax=docker/dockerfile:1

##############
# BASE
##############
FROM php:8.2.10-cli-bookworm@sha256:750aca14502f934bd3d493a6e57835928d4e6ca1bc093b144670c049dc4b18c8 as base

# disable interactive mode when configuring installed packages
ARG DEBIAN_FRONTEND=noninteractive
# allow running composer as root
ARG COMPOSER_ALLOW_SUPERUSER=1

# set composer directories
ENV COMPOSER_HOME=/home/app/.composer
ENV COMPOSER_CACHE_DIR=/home/app/.composer-cache

# default application data directory
ENV APP_DATA_DIR=/app/var/data

# copy composer executable
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# copy php extension installer
COPY --from=mlocati/php-extension-installer:2.1.44 /usr/bin/install-php-extensions /usr/local/bin/

# set wkhtmltox version (availabe only on build time)
ARG WKHTMLTOX_VERSION=0.12.6.1-3

# change shell so we can use bash arrays
SHELL ["/bin/bash", "-ce"]

RUN <<-"EOT"
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
  # install wkhtmltopdf for selected architecture
  arch=$(dpkg --print-architecture | awk -F- '{ print $NF }')
  wkhtmltox_deb=wkhtmltox_${WKHTMLTOX_VERSION}.bookworm_${arch}.deb
  curl --location --silent --show-error --output /tmp/${wkhtmltox_deb} \
    https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/${wkhtmltox_deb}
  dpkg -i  /tmp/${wkhtmltox_deb}
  rm -rf /tmp/${wkhtmltox_deb}
  apt-get autoremove -y
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  # create `app` group and `app` user with default UID/GID equal to 1000
  groupadd -g 1000 -o app
  useradd -m -u 1000 -g 1000 -d /home/app -o -s /bin/bash app
  # create home and cache directories for composer
  mkdir -p $COMPOSER_HOME $COMPOSER_CACHE_DIR
  chown -R app:app $COMPOSER_HOME $COMPOSER_CACHE_DIR $APP_DATA_DIR
EOT

WORKDIR /app

##############
# DEV
##############
FROM base as dev

ENV APP_ENV=dev

# fetch UID/GID from build args
ARG APP_UID=1000
ARG APP_GID=1000

RUN <<-"EOT"
  apt-get update
  # install some additional handy utils
  apt-get install -y --no-install-recommends iputils-ping iproute2 nano
  install-php-extensions xdebug-3.2.0
  # change GID of app group
  groupmod -g ${APP_GID} app
  # change UID of app user
  usermod -u ${APP_UID} app
  # fix ownership of composer and data directories
  chown -R app:app $COMPOSER_HOME $COMPOSER_CACHE_DIR $APP_DATA_DIR
EOT

# deafult command for local development and CI
# used just for keeping container running
CMD ["tail", "-f", "/dev/null"]

##############
# CI
##############
FROM dev as ci

ENV APP_ENV=ci

# copy packages configuration
COPY composer.json composer.lock ./

# install all packages including dev packages (required for code style checks, tests etc)
RUN composer install --no-interaction

COPY . .

##############
# PROD
##############
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