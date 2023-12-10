Let's make some assumptions first:

* I have a simple PHP CLI app
* Multiple developers are working on it
* Developers are using different Operating systems and architectures
  * Linux
  * Windows with WSL2
  * macOS (M1 or newer)
* Developers have installed modern versions of `docker`, `docker compose` and `make`


What I want to achieve:

* Automate as much as possible so devs will just use simple commands to run tasks
* Use a very similar configuration in CI as in local dev to minimize situations 
  when something works on local dev but not in CI and vice versa
* Everything should work the same way on Linux, Windows and macOS.

What I will use to achieve this:

* [Docker](https://docs.docker.com/engine/) for building and running apps across 
  multiple operating systems and architectures
* [Docker Compose](https://docs.docker.com/compose/) for easy project setup and 
  run on a local dev machine and in CI
* [Make](https://www.gnu.org/software/make/manual/make.html) - automating tasks
* [GitHub Action](https://docs.github.com/en/actions) as CI tool


## Project structure

```text
.
├── .github
│   └── workflows
│       └── qa.yml            <= github workflow for PR
├── var
│   ├── cache
│   │   └── .gitkeep
│   ├── data                  <= app data
│   │   └── .gitkeep
│   └── logs
│       └── .gitkeep                   
├── application.php           <= application "main" code 
├── compose.arm64.yml         <= compose config for arm64 architectures 
├── compose.ci.yml            <= compose config for CI
├── compose.dev.yml           <= compose config for local dev
├── compose.override.yml      <= local config for compose (not in GIT)
├── composer.json             <= php composer project config (dependencies etc) 
├── composer.lock             <= php composer lock file with exact packages to install
├── compose.yml               <= docker compose "main" configuration file
├── Dockerfile                <= docker image build instructions
├── .dockerignore
├── .gitignore
├── Makefile                  <= automation configuration
└── .php-cs-fixer.dist.php    <= code style configuration
```

## For building and running use Docker and Dockerfile

Here is a Dockerfile I will use to build the application image.

```dockerfile
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
ARG APP_HOME=/home/app
ENV COMPOSER_HOME=${APP_HOME}/.composer
ENV COMPOSER_CACHE_DIR=${APP_HOME}/.composer-cache

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
  useradd -m -u 1000 -g 1000 -d "$APP_HOME" -o -s /bin/bash app
  # create home and cache directories for composer
  mkdir -p $COMPOSER_HOME $COMPOSER_CACHE_DIR
  # set app user as owner
  chown -R app:app $COMPOSER_HOME $COMPOSER_CACHE_DIR
EOT

WORKDIR /app

# deafult command
# will run application.php without args which should show command help and exit
CMD ["php", "application.php"]

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
  # fix ownership of composer directories and app user home directory
  # need to be done after changing UID/GID
  chown -R app:app $COMPOSER_HOME $COMPOSER_CACHE_DIR $APP_HOME
EOT

# deafult command for local development and CI
# used just for keeping container running
CMD ["tail", "-f", "/dev/null"]

# run as app user by default
USER app:app

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

# set ownership for all dirs inside var/ to app user
RUN chown -R app:app var/*

# run as app user by default
USER app:app

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

# set ownership for all dirs inside var/ to app user
RUN chown -R app:app var/*

# run as app user by default
USER app:app
```

I'm using a [multistage build](https://docs.docker.com/build/building/multi-stage/) 
to separate and reuse parts of the image.

### The `base` stage

As the name suggests, this stage is used as a base for all other stages. Here 
I'm doing things like:

* setting environment variables (build time only and global) to use on container run
* installing system packages, php extensions and tools

One thing to note is how I'm installing `wkhtmltox` library. OS architecture 
is extracted from `dpkg --print-architecture` command output, and then it is 
used to download the architecture-specific deb package. It will be handy for 
macOS users as they will need `arm64` version of this package.

### The `dev` stage

This stage is built on top of `base` stage and used as a target for local dev 
image. Here I'm making some additional changes for developers like:

* setting `APP_ENV` to `dev` so the application will know that we are local dev 
  env, and it can work a little differently than in the production version 
  (like disabling caching, loading different dotenv files, enabling debug 
  extensions etc.)
* installing additional packages and php extensions that are useful for local 
  development
* fix UID/GID and permissions for `app` user to match developer UID/GID
* setting the default container command so the container will run until stopped


Please note the use of build args, `APP_UID` and `APP_GID`. I'm using them to 
adjust the UID and GID of the `app` user. The `app` user by default is using 
`UID=1000` and `GID=1000`. All files created by the `app` user (like logs, 
cache, temp files, reports etc.) will be owned by UID/GID of the `app` user. 
This may be a problem for developers working locally because they are mounting 
the whole project directory inside the running container (under `/app` directory). 
There can be some file permission issues because the developer UID/GID and `app` 
UID/GID inside the container may be different.

Here is an example from my local machine:

```shell
$ id
uid=1001(piotrekkr) gid=1001(piotrekkr) groups=1001(piotrekkr),90(network),98(power),108(vboxusers),970(docker),991(lp),998(wheel),1000(autologin)
```

To "fix" this issue, in `dev` stage, I'm updating UID/GID of `app` user to match 
the UID/GID of the developer who is building the application image.

### The `ci` stage

This stage is built upon `dev` stage and actually copy project files and install 
packages. The built image will include a fully functional application with all 
packages (including development ones) installed and ready to use. I will use 
this image in CI to run some quality checks like code formatting, etc. 
It will also help me check if the build process works correctly. After all, 
someone could change a line in `Dockerfile` that breaks the build and I should 
catch it early. Since I actually copied files inside image, I'm also fixing 
permissions to `var/*` so `app` user can write to them.  

### The `production` stage

This stage looks similar to CI stage but:

* There shouldn't be dev stuff in the production image, so I use `base` stage as a base
* `APP_ENV` is set to `prod` so the application knows that it is a production env
* I'm installing only production packages (`--no-dev` option for `composer`)

## For easy project setup use Docker Compose

> Compose is a tool for defining and running multi-container Docker applications. 
> With Compose, you use a YAML file to configure your application's services. 
> Then, with a single command, you create and start all the services from your 
> configuration.

The above snippet from documentation accurately describes what `Compose` tool 
is used for. Without it setting up a project with multiple services (containers) 
would be painful. I would need to manually run commands to build app images, 
create networks and volumes, run containers (with those networks and volumes), 
show logs, stop services, and many more. Also, I would need to do this in proper 
order because services can depend on other services. Compose is doing all this 
work for me.

I'm using multiple compose configuration files. Compose allows for loading 
multiple files at the same time, so depending on where compose is running and 
what is the OS architecture, I will choose the proper configuration files to load.

### compose.yml

```yaml
version: '3.7'

services:
  app:
    # local dev container image name
    # when build is done, image will be tagged like docker.io/library/app:dev
    image: app:dev
    build:
      # default target for local dev
      target: dev
      context: .
      dockerfile: Dockerfile
      args:
        # pass current user UID/GID as build arg
        # compose will substitute ${APP_UID} and ${APP_GID} with values from environment
        APP_UID: ${APP_UID}
        APP_GID: ${APP_GID}
    depends_on:
      # db need to be started before the app
      db:
        condition: service_started
  db:
    image: postgres:15-bookworm
    environment:
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: apppass
      POSTGRES_DB: appdb
    volumes:
      - db_data:/var/lib/postgresql/data:rw

volumes:
  db_data:
```

This is a "base" compose file that defines all services needed by the project. 
I will always load this file as the first configuration file before any other.

A few things to note:

* I intentionally do not set any volume in the `app` service because the volume 
  is not needed in CI and is set differently for macOS (with Mutagen) and also 
  for Linux.
* I expect that environment variables like `APP_GID` and `APP_UID` to be set 
  when compose is running

### compose.dev.yml

```yaml
services:
  app:
    volumes:
      - .:/app
```

This file will be loaded when developing on a local machine with Linux. Here 
I'm just adding a volume mount so the full project directory is mounted under 
`/app` inside the `app` container. I will load this file as the next one after 
`compose.yml`.

### compose.ci.yml

```yaml
services:
  app:
    image: ${CI_IMAGE_TAG}
    volumes:
      # mount logs/ inside container, so we can have them easily accessible on host
      - ./var/data:/app/var/data
```

This is an additional configuration loaded when operating in CI. I'm not mounting 
application code inside the CI container because the CI image should already 
contain a fully functional application. On the other hand, I want to be able to 
see some report files that are generated when the application is running in CI. 
To achieve this, I'm mounting a local directory `./var/data` into container 
`/app/var/data`. All files created inside container `/app/var/data` will show up 
on the host machine in `./var/data`.

Please note the usage of `CI_IMAGE_TAG` environment variable that should be 
unique per each workflow run. Creating a pull request or pushing new commits 
will trigger a workflow run in CI that will generate and push the app image 
to `ghcr.io` (GitHub docker registry). At the same time, there can be multiple 
workflow runs from different pull requests. By using a unique docker image tag 
for each CI workflow run, I can be sure that new images will not override existing 
ones inside the registry.

### compose.arm64.yml

```yaml
services:
  app:
    volumes:
      # mount mutagen managed volume for better performance
      - app:/app

volumes:
  app:

x-mutagen:
  sync:
    defaults:
      ignore:
        vcs: true
        paths:
          - .idea # PHPStorm directory
          - .DS_Store # macOS files
      configurationBeta:
        permissions:
          defaultFileMode: 0644
          defaultDirectoryMode: 0755
          defaultOwner: id:${APP_UID}
          defaultGroup: id:${APP_GID}
    app:
      alpha: .
      beta: volume://app
      mode: two-way-resolved
```

As I mentioned before, file synchronization from macOS to docker is very slow. 
To improve on this, I'm setting some [mutagen](https://mutagen.io/documentation/introduction) 
configuration. It will still be slower than Linux but way better than the 
original macOS speed.

### compose.override.yml

```yaml
services: {}
```

This file is loaded as the last one on non-CI environments. It is not tracked 
by GIT and can be used by developers to modify some compose configurations to 
their specific needs. For example, a developer may want to set some container-level 
environment variable just for their own local dev environment. It can be done 
like this:

```yaml
services:
  app:
    environment:
      XDEBUG_MODE: debug
      XDEBUG_START_WITH_REQUEST: 'yes' #watch out for booleans in yaml
```

Since this file is not tracked, it will not affect anyone else. This file is 
generated automatically by `make` (if not exist) on local dev environments.

## `Make` to connect them all

> GNU Make is a tool which controls the generation of executables and other 
> non-source files of a program from the program's source files.

Make is mostly focused on generating executables, but it can also be used to 
automate tasks. With `make` I will be able to "connect" Docker, Dockerfile and 
Docker Compose and automate project setup and common tasks like managing app 
lifecycle, checking code style, installing packages etc.

Here is a Makefile I will use:

```Makefile
.SILENT:

# get OS architecture
UNAME := $(shell uname -m)

# default compose command
COMPOSE_CMD = docker compose
# compose config files list
COMPOSE_CONFIGS = -f compose.yml

ifeq ($(CI), true) # Configuration for CI
COMPOSE_CONFIGS += -f compose.ci.yml
# disable fancy buildkit output when building images
export BUILDKIT_PROGRESS = plain
else ifeq ($(UNAME), arm64) # Configuration for macOS (M1 and later)
# we need to use Mutagen because file sync with docker sucks
COMPOSE_CMD = mutagen-compose
# additional macOS specific config
COMPOSE_CONFIGS += -f compose.arm64.yml
else # Default configuration
COMPOSE_CONFIGS += -f compose.dev.yml
endif

ifneq ($(CI), true) # if we are not in CI
# compose.override.yml file must exist before docker compose is executed
# by default it is ignored in GIT and it needs to be created for local development
$(shell test -f compose.override.yml || echo 'services: {}' > compose.override.yml)
# add local override compose config to config list
COMPOSE_CONFIGS += -f compose.override.yml
endif

# test if we can allocate tty by checking if stdin is a tty
# fixes some problems with git hooks and docker compose not able to guess tty
$(shell test -t 0)
ifeq ($(.SHELLSTATUS), 1)
ALLOCATE_TTY = -T
endif

# glue compose command for reuse later
COMPOSE := $(COMPOSE_CMD) $(COMPOSE_CONFIGS)

# execute command in already running app container
EXEC_APP := $(COMPOSE) exec $(ALLOCATE_TTY) app

# run command in new app container without starting any other services
RUN_APP_NO_DEPS := $(COMPOSE) run --no-deps $(ALLOCATE_TTY) app

# execute command in already running app container as root
EXEC_APP_ROOT := $(COMPOSE) exec $(ALLOCATE_TTY) --user root app

# get running user UID/GID and export as env vars for all targets
export APP_UID ?= $(shell id -u)
export APP_GID ?= $(shell id -g)

build:
	$(COMPOSE) build

start:
	$(COMPOSE) up -d --remove-orphans
	$(MAKE) install

build-start:
	$(MAKE) build
	$(MAKE) start

stop:
	$(COMPOSE) stop

down:
	# stop app and remove all containers and volumes
	$(COMPOSE) down --volumes --remove-orphans

status:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs

install:
	$(EXEC_APP) composer install

cli:
	$(EXEC_APP) bash

cli-root:
	$(EXEC_APP_ROOT) bash

cs-check:
	$(RUN_APP_NO_DEPS) vendor/bin/php-cs-fixer check

cs-fix:
	$(RUN_APP_NO_DEPS) vendor/bin/php-cs-fixer fix

generate-report:
	$(EXEC_APP) php application.php generate-report

# make targets above as phony targets, they should be always executed
# even if files with same name already exist in project
# https://www.gnu.org/software/make/manual/html_node/Phony-Targets.html
.PHONY: build start build-start stop down status logs install cli cli-root cs-check cs-fix generate-report
```

When I run some targets, such as `make build`, `Make` will:

1. check where it is executed
2. choose the appropriate command to use (`docker compose` or `mutagen-compose`)
3. prepare a list of configuration files to use by `docker compose`
4. create `compose.override.yml` if needed
5. disable compose `TTY` if needed
6. setup environment variables (like UID/GID of running user etc.)
7. run actual target command

In daily work as a developer, I would just run some simple make commands to do 
tasks like:

* I just cloned the project repo, and I want to start working on the project -
  `make build-start`
* It is another day and I need to work on this project again - `make start`
* Something is not right with the app and I need to see logs - `make logs`, 
  `make status`
* I switched to a branch with different dependencies and I need to install them - 
  `make install`
* I need to go into the container and run some custom commands - `make cli`
* I've updated `Dockerfile` and I need to rebuild app container - `make build`
* I've changed some source files and need to be sure the code style is correct - 
  `make cs-fix`
* Need to work on another project - `make stop`

Commands are convenient to use and easy to remember. 

## CI

In CI I will also use `make` commands to run tasks. Below is an example of how 
to use `make` with GitHub Actions.

```yaml
name: Quality Assurance

on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

concurrency:
  group: quality-assurance-${{ github.ref }}
  cancel-in-progress: true

env:
  # set CI image tag to use in all jobs
  CI_IMAGE_TAG: ghcr.io/${{ github.repository }}:ci-run-${{ github.run_id }}

jobs:
  build-ci-image:
    name: Build CI Image
    timeout-minutes: 10
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout App Code
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Log into container registry
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set Up Buildx
        id: buildx
        uses: docker/setup-buildx-action@v2

      - name: Get UID/GID Of GitHub Action User
        id: gha
        run: |
          echo "uid=$(id -u)" >> $GITHUB_OUTPUT
          echo "gid=$(id -g)" >> $GITHUB_OUTPUT

      - name: Build App Image
        uses: docker/build-push-action@v4
        id: build
        with:
          context: .
          target: ci
          # use buildx builder
          builder: ${{ steps.buildx.outputs.name }}
          build-args: |
            APP_UID=${{ steps.gha.outputs.uid }}
            APP_GID=${{ steps.gha.outputs.gid }}
          file: Dockerfile
          # do not push image
          push: true
          tags: ${{ env.CI_IMAGE_TAG }}
          # use GItHub Actions cache
          cache-from: type=gha
          cache-to: type=gha,mode=max

  php-cs-fixer-check:
    name: PHP CS Fixer Check
    needs: [build-ci-image]
    timeout-minutes: 5
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Log into container registry
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Run PHP CS Fixer
        run: make cs-check

  generate-report:
    name: Generate Report
    needs: [build-ci-image]
    timeout-minutes: 5
    runs-on: ubuntu-22.04
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Log into container registry
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Start application
        run: make start

      - name: Generate Report
        run: make generate-report

      - name: Show file permissions in data directory
        run: ls -la var/data

      - name: Show Report Results
        run: cat var/data/report.txt
```