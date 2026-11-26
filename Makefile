# herdr-haptic-notify — developer tasks
#
# Every target is plain shell + node; no npm install, no bundler.

SHELL := /bin/sh
PLUGIN_ID := haptic-notify
REPO_ROOT := $(shell pwd)
CONFIG_DIR := $(HOME)/.config/herdr/plugins/config/$(PLUGIN_ID)

.PHONY: help build test test-fast lint hooks install uninstall lab clean ci

help:
	@printf 'targets:\n'
	@printf '  make build      build bin/taptic (or fetch a prebuilt release asset)\n'
	@printf '  make test       full test suite (node --test)\n'
	@printf '  make test-fast  pure-logic tests only (~1s, used by the git hook)\n'
	@printf '  make lint       syntax checks + shellcheck when available\n'
	@printf '  make hooks      install .githooks as core.hooksPath\n'
	@printf '  make install    build, link the plugin into herdr, seed config\n'
	@printf '  make uninstall  unlink the plugin from herdr\n'
	@printf '  make lab        open the Haptic Lab UI (http://127.0.0.1:8765)\n'
	@printf '  make clean      remove build output\n'

build:
	@sh scripts/build-taptic.sh

test:
	@node --test

test-fast:
	@node --test test/sequence.test.js

lint:
	@node --check hook.js
	@node --check lib/sequence.js
	@node --check lab/server.mjs
	@node -e 'JSON.parse(require("fs").readFileSync("config.example.json","utf8"))'
	@node -e 'JSON.parse(require("fs").readFileSync("lab/presets.json","utf8"))'
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck scripts/*.sh install.sh; \
	else \
		printf 'shellcheck not installed — skipping shell lint\n'; \
	fi

hooks:
	@git config core.hooksPath .githooks
	@printf 'core.hooksPath -> .githooks (pre-commit runs lint + fast tests)\n'

install: build
	@sh install.sh

uninstall:
	@herdr plugin unlink $(PLUGIN_ID) || true

lab:
	@node lab/server.mjs --open

ci: lint test build
	@printf 'ci ok\n'

clean:
	@rm -rf bin
	@printf 'removed bin/\n'
