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
BUILDKIT_PROGRESS = plain
else ifeq ($(UNAME), arm64) # Configuration for MacOS (M1 and later)
# we need to use Mutagen because file sync with docker sucks on MacOS
COMPOSE_CMD = mutagen-compose
# additional MacOS specific config
COMPOSE_CONFIGS += -f compose.arm64.yml
else # Default configuration
COMPOSE_CONFIGS += -f compose.dev.yml
endif

ifneq ($(CI), true) # if we are not in CI
# compose.override.yml file must exist before docker compose is executed
# by default it is ignored in GIT so it needs to be created for local development
$(shell test -f compose.override.yml || echo 'version: "3.7"' > compose.override.yml)
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
EXEC_APP = $(COMPOSE) exec $(ALLOCATE_TTY) -u www-data app

# execute command in already running app container as root
EXEC_APP_ROOT = $(COMPOSE) exec $(ALLOCATE_TTY) app

# get running user UID/GID and export as env vars for all targets
export WWW_DATA_UID ?= $(shell id -u)
export WWW_DATA_GID ?= $(shell id -g)

.PHONY: build
build:
	$(COMPOSE) build

.PHONY: start
start:
	$(COMPOSE) up -d
	$(MAKE) install

.PHONY: stop
stop:
	$(COMPOSE) stop

.PHONY: install
install:
	$(EXEC_APP) composer install

.PHONY: cli
cli:
	$(EXEC_APP) bash

.PHONY: cli-root
cli-root:
	$(EXEC_APP_ROOT) bash

.PHONY: cs-check
cs-check:
	$(EXEC_APP) vendor/bin/php-cs-fixer check

.PHONY: cs-fix
cs-fix:
	$(EXEC_APP) vendor/bin/php-cs-fixer fix

.PHONY: hello
hello:
	$(EXEC_APP) php application.php hello DEV
