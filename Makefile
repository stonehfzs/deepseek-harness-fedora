# DeepSeek Harness packaging — developer entry points.
#
# Everything is driven from scripts/versions.env (the single source of truth for
# the pinned upstream runtime) and scripts/*.sh. Run `make` or `make help` for
# the list of targets.

SHELL := /bin/bash
REPO_ROOT := $(CURDIR)
TARGET ?= linux-x64
RPM ?= $(firstword $(wildcard $(REPO_ROOT)/build/rpmbuild/RPMS/*/*.rpm))

.DEFAULT_GOAL := help
.PHONY: help fetch rpm srpm portable smoke test lint srpm-check clean dist install

help: ## Show this help
	@awk 'BEGIN { FS = ":.*##"; printf "\nDeepSeek Harness packaging\n\nUsage: make <target>\n\n" } \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nVariables: TARGET=%s (linux-x64, linux-arm64, macos-arm64, macos-x64, windows-x64)\n\n" "$(TARGET)"

fetch: ## Download + verify the pinned upstream runtime wheel
	@scripts/fetch-runtime.sh $(TARGET)

rpm: ## Build the Fedora RPM (linux-x64) into build/rpmbuild/RPMS/
	@scripts/build-rpm.sh

srpm: ## Build a source RPM (embeds the pinned wheel, rebuilds offline)
	@scripts/build-rpm.sh --srpm

portable: ## Build a portable bundle for TARGET into dist/
	@scripts/build-portable.sh $(TARGET)

smoke: ## Extract the built RPM and run it (no root required)
	@scripts/smoke-test.sh "$(RPM)"

test: smoke ## Alias for smoke

lint: ## Check specs, shell scripts, desktop/AppStream metadata
	@scripts/lint.sh

srpm-check: ## Rebuild the RPM from the generated SRPM (offline proof)
	@scripts/build-rpm.sh --from-srpm

install: ## Install the built RPM (needs root; use with sudo)
	@test -n "$(RPM)" || { echo "no RPM built yet: run 'make rpm'" >&2; exit 1; }
	sudo dnf install -y "$(RPM)"

dist: clean ## Build RPM + portable bundles for every published target
	@scripts/build-rpm.sh
	@for t in linux-arm64 macos-arm64 macos-x64 windows-x64; do scripts/build-portable.sh $$t; done

clean: ## Remove build outputs (keeps the download cache)
	rm -rf $(REPO_ROOT)/build $(REPO_ROOT)/dist

distclean: clean ## Remove build outputs and the download cache
	rm -rf $(REPO_ROOT)/.cache
