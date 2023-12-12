## Introduction

In today's fast-paced development environment, where multiple developers are
collaborating on projects using different operating systems and architectures,
automating development and CI tasks is crucial for consistency and efficiency.
This blog post explores the integration of Docker Compose and the versatile
`make` tool to streamline the development and CI processes for a simple PHP CLI 
application.

### Tools used

* [Docker](https://docs.docker.com/engine/) for building and running apps across 
  multiple operating systems and architectures
* [Docker Compose](https://docs.docker.com/compose/) for easy project setup and 
  run on a local dev machine and in CI
* [Make](https://www.gnu.org/software/make/manual/make.html) - automating tasks
* [GitHub Action](https://docs.github.com/en/actions) as CI tool


## Project structure

Before delving into the automation setup, let's outline the project structure:

```text
.
├── .github
│   └── workflows
│       └── qa.yml            <= GitHub workflow for PR  
├── var
│   ├── cache
│   │   └── .gitkeep
│   ├── data                  <= application data  
│   │   └── .gitkeep
│   └── logs
│       └── .gitkeep
├── application.php           <= CLI application code
├── compose.arm64.yml         <= Compose config for arm64 architectures
├── compose.ci.yml            <= Compose config for CI
├── compose.dev.yml           <= Compose config for local dev
├── compose.override.yml      <= Local config for Compose (not in GIT)
├── composer.json             <= PHP Composer project config (dependencies, etc.)
├── composer.lock             <= PHP Composer lock file with exact packages to install
├── compose.yml               <= Docker Compose "main" configuration file
├── Dockerfile                <= Docker image build instructions
├── .dockerignore
├── .gitignore
├── Makefile                  <= Automation configuration  
└── .php-cs-fixer.dist.php    <= Code style configuration  
```

## Dockerfile and Multistage Build

To build and run the PHP CLI application across different environments,
I will use a Dockerfile with a [multistage build](https://docs.docker.com/build/building/multi-stage/)
approach.

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
USER app

##############
# CI
##############
FROM dev as ci

# switch back to root to install vendor packages and copy files
USER root

ENV APP_ENV=ci

# copy packages configuration
COPY composer.json composer.lock ./

# install all packages including dev packages (required for code style checks, tests etc)
RUN composer install --no-interaction

COPY . .

# set ownership for all dirs inside var/ to app user
RUN chown -R app:app var/*

# run as app user by default
USER app

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
USER app
```

Multistage build allows me to separate and reuse parts of the image.
Below is a summary of the key stages:

### The `base` stage

This stage sets environment variables, installs system packages, PHP extensions,
and tools. I use it as a "base" for other stages. 

One thing to note is how I'm installing `wkhtmltox` library. OS architecture 
is extracted from `dpkg --print-architecture` command output, and it is 
used to download the architecture-specific `deb` package. This allows macOS users 
to install proper `arm64` version of this package.

### The `dev` stage

Built upon the `base` stage, this stage customizes settings for local development.
I'm adjusting the `APP_ENV` variable and installing additional packages specific to 
development environment.

Note that at this stage I'm also adjusting `UID` and `GID` of `app` user to match 
the ones used by developer. It is done to address possible discrepancies 
between the host and the container for smoother local development. 

### The `ci` stage

This stage, built on `dev`, copies project files and installs both development
and production packages. It's designed for use in CI environments,
facilitating quality checks and validating the build process.

Please note that after `COPY` command, files are owned by `root` and application 
will be run as `app` user. Application needs a write access to directories 
inside `var/`. As a fix, I'm changing ownership of those directories to `app` user. 

### The `production` Stage

Similar to the `ci` stage but without development dependencies, this stage is 
tailored for production use.

## Docker Compose for Seamless Project Setup

Docker Compose simplifies the orchestration of multi-container Docker applications.
Without this tool, setting up a project with multiple containers would require 
a lot of "manual" work. I would need to prepare commands for building app image, 
creating networks and volumes, managing containers (with those networks and volumes), 
showing logs, and many more. Also, services can depend on other services and I 
would need to start them in proper order. Compose is doing all this work for me.

Compose allows for loading multiple files at the same time. Depending on 
where compose is running and what is the OS architecture, I will choose the 
proper configuration files to load.

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

Not setting any volume in the `app` service is intentional. Volume with project 
files is not needed when in CI and is set differently when running on macOS 
(with Mutagen). I also expect that environment variables `APP_GID` and `APP_UID` 
are set before compose is started.

### compose.dev.yml

```yaml
services:
  app:
    volumes:
      - .:/app
```

Loaded for local development on Linux, this file introduces volume mounts for
the entire project directory inside the `app` container. I will load this file 
as the next one after `compose.yml`.

### compose.ci.yml

```yaml
services:
  app:
    image: ${CI_IMAGE_TAG}
    volumes:
      # mount logs/ inside container, so we can have them easily accessible on host
      - ./var/data:/app/var/data
```

This is an additional configuration loaded when running in CI. I'm relying on 
pre-built CI image to run CI tasks (defined in `CI_IMAGE_TAG`). 

I'm mounting only a local directory `./var/data` into container `/app/var/data`. 
My goal is to be able to access all files created inside container `/app/var/data` 
on the host machine.

Please note the usage of `CI_IMAGE_TAG` environment variable that should be 
unique per each workflow run. Creating a pull request or pushing new commits 
will trigger a workflow run in CI that will generate and push the app image 
to `ghcr.io` (GitHub docker registry). At the same time, there can be multiple 
workflows running from different pull requests. By using a unique docker image tag 
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

Loaded as the last one on non-CI environments. Not tracked by GIT. It can be used 
by developers to modify compose configurations to their specific needs. For 
example, a developer may want to set some container-level environment variable 
just for their own local dev environment. It can be done 
like this:

```yaml
services:
  app:
    environment:
      XDEBUG_MODE: debug
      XDEBUG_START_WITH_REQUEST: 'yes' #watch out for booleans in yaml
```

Because this file is not tracked, changes will not affect anyone else. It is 
generated automatically by `make` (if not exist) on local dev environments.

## Utilizing Make for Automation

> GNU Make is a tool which controls the generation of executables and other 
> non-source files of a program from the program's source files.

Make is mostly focused on generating executables, but it can also be used to 
automate tasks. It will serve me as the glue to connect Docker, Docker Compose, 
and various project tasks such as building, starting and stopping project, 
checking code style, etc.

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

When I run targets, such as `make build`, it will:

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

Using `make` targets is convenient and easy to remember. 

## CI Integration with GitHub Actions

In CI, Make commands seamlessly integrate with GitHub Actions

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
  # set CI image tag as env var to use in all jobs
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

Workflow will run when pull request is created or updated or when there is a 
commit pushed to `main` branch. It contains three jobs.

### Build CI Image Job

In this job, I'm building and pushing CI version of app image to GitHub container 
registry. This image will then be used by other jobs to execute checks and other 
application commands.

Please note that I do not use `make build` to build CI image. I want to use 
buildx with GitHub cache to speed up build. It cannot be easily done with Docker 
Compose when in CI, so I'm using `docker/build-push-action@v4` to manage all this 
for me.

### PHP CS Fixer Check Job

Depends on successful execution of `Build CI Image` job. It will clone 
application code, authenticate in `ghcr.io` and run `make cs-check`. 

In the background, `make` will call `docker compose -f compose.yml 
-f compose.ci.yml run --no-deps  app vendor/bin/php-cs-fixer check` 
command that in turn will pull `app` image from `ghcr.io` (tagged with 
`CI_IMAGE_TAG` value) and start `app` container with `vendor/bin/php-cs-fixer check` 
command. 

### Generate Report Job

Similar to the previous job but starts the entire project, allowing for report 
generation with necessary dependencies. It was not the case with code style 
check because this check requires only `app` service to run.

## Conclusion

I'm leveraging Docker Compose, Dockerfile multistage builds, and Make, to provide 
a consistent and efficient development and CI experience across multiple 
environments. Whether developers are working on Linux, Windows with WSL2, or macOS, 
they can focus on coding, relying on streamlined commands and automated 
processes for project tasks. By adopting this approach, I can provide a reliable 
development pipeline and minimizing discrepancies between local development 
and CI environments.

## Bonus — Alternatives to Make

Although GNU Make does its job, it may seem outdated and not best for the job.
Fortunately, there are other projects that could be used as a replacement:

- [just](https://github.com/casey/just) - a handy way to save and run
  project-specific commands.
- [task](https://github.com/go-task/task) - Task is a task runner / build tool
  that aims to be simpler and easier to use than, for example, GNU Make.

