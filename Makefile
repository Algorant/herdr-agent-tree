.PHONY: build test fmt clippy shell-check test-installer release-test check-version check ci release-check stage-local stage-local-release link link-disabled unlink logs

HERDR ?= herdr
CARGO ?= cargo
PLUGIN_ID := agent-tree

# Explicit locked build. Clippy and the test harness also compile, but this is the
# standalone build gate required by CI.
build:
	$(CARGO) build --locked

test:
	$(CARGO) test --locked --all-targets

fmt:
	$(CARGO) fmt --all -- --check

clippy:
	$(CARGO) clippy --locked --all-targets --all-features -- -D warnings

shell-check:
	sh -n scripts/*.sh test/*.sh install.sh

test-installer:
	./test/test-install.sh

release-test:
	./test/test-release.sh

check-version:
	./scripts/check-release.sh

check: fmt clippy test build shell-check test-installer release-test check-version

ci: check

# Final publication gate. It fails closed until the owner promotes a target with
# version-bound native evidence in release-targets.txt. Nothing is published by this target.
release-check: check
	./scripts/check-release.sh
	./scripts/check-release-targets.sh

stage-local:
	$(CARGO) build --locked --bins
	./scripts/stage-local.sh --force

stage-local-release:
	$(CARGO) build --locked --release --bins
	./scripts/stage-local.sh --profile release --force

link:
	$(HERDR) plugin link "$(CURDIR)" --enabled

link-disabled:
	$(CARGO) build --locked --bins
	$(HERDR) plugin link "$(CURDIR)" --disabled

unlink:
	$(HERDR) plugin unlink $(PLUGIN_ID)

logs:
	$(HERDR) plugin log list --plugin $(PLUGIN_ID)
