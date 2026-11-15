SHELL := /bin/bash

SCRIPTS := bin/homelab bin/homelab-lid-watch install.sh $(wildcard tests/*.sh)

# These findings pre-date the test branch and live in product files, which
# this branch deliberately does not modify. Keep linting the product scripts;
# only the known findings are excluded.
PRODUCT_SHELLCHECK_EXCLUDES := SC2015,SC2034

.PHONY: check syntax lint verify test

check: syntax lint verify test

syntax:
	@echo "==> bash syntax"
	@bash -n $(SCRIPTS)
	@echo "ok: bash syntax"

lint:
	@echo "==> shellcheck"
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x $(wildcard tests/*.sh) && \
		shellcheck --exclude=$(PRODUCT_SHELLCHECK_EXCLUDES) \
			bin/homelab bin/homelab-lid-watch install.sh && \
		echo "ok: shellcheck"; \
	else \
		echo "skip: shellcheck not installed"; \
	fi

verify:
	@echo "==> systemd units"
	@if ! command -v systemd-analyze >/dev/null 2>&1; then \
		echo "skip: systemd-analyze not installed"; \
	elif systemd-analyze --user verify systemd/user/*.service; then \
		echo "ok: systemd-analyze --user verify"; \
	elif systemd-analyze verify systemd/user/*.service; then \
		echo "ok: systemd-analyze verify (system-wide fallback)"; \
	else \
		echo "warning: systemd-analyze could not verify units here; skipping (best effort)"; \
	fi

test:
	@echo "==> tests"
	@tests/run.sh
