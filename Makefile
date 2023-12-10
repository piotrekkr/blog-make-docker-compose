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
EXEC_APP := $(COMPOSE) exec $(ALLOCATE_TTY) -u app app

# run command in new app container without starting other services
RUN_APP_NO_DEPS := $(COMPOSE) run --no-deps $(ALLOCATE_TTY) -u app app

# execute command in already running app container as root
EXEC_APP_ROOT := $(COMPOSE) exec $(ALLOCATE_TTY) app

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