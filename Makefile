.PHONY: help test-issues test-ubuntu test-local test-suite test-docker test-templates test-pi-agents-local test-smithers lint clean build-docker shell-ubuntu init-submodules

help:
	@echo "Chezmoi Dotfiles - Available commands:"
	@echo ""
	@echo "  make test-issues      Validate repository issues and run their Python tests"
	@echo "  make test-ubuntu      Run tests in Ubuntu Docker container"
	@echo "  make test-suite       Run the post-apply suite in parallel (host-safe files)"
	@echo "  make test-templates   Run template tests only (fast, no apply)"
	@echo "  make test-pi-agents-local  Run focused Pi local-instructions extension tests"
	@echo "  make test-smithers    Install, type-check, and test the Smithers package"
	@echo "  make test-local       Run chezmoi diff on current machine (dry-run)"
	@echo "  make test-docker      Build and run full Docker test suite"
	@echo "  make lint             Run shellcheck on all scripts"
	@echo "  make shell-ubuntu     Open interactive shell in Ubuntu container"
	@echo "  make build-docker     Build Docker image without running tests"
	@echo "  make clean            Remove Docker containers and images"

init-submodules:
	@if [ ! -f tests/helpers/bats-libs/bats-support/load.bash ]; then \
		echo "Initializing bats-libs submodules..."; \
		git submodule update --init --recursive; \
	fi

test-issues:
	python3 scripts/issues validate
	python3 -m unittest discover -s tests -p 'test_*.py'

build-docker: init-submodules
	docker compose -f docker/docker-compose.yml build

test-ubuntu: test-issues build-docker
	docker compose -f docker/docker-compose.yml run --rm test-ubuntu

test-templates: test-issues build-docker
	docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu \
		'set -e && (cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/) && \
		chezmoi init --source=/home/testuser/.local/share/chezmoi --promptString name="Test User" --promptString email="test@example.com" && \
		bats tests/templates.bats'

test-pi-agents-local:
	bun test tests/pi-agents-local-extension.test.ts

test-smithers:
	cd home/private_dot_claude/dot_smithers && bun install --frozen-lockfile
	cd home/private_dot_claude/dot_smithers && bun run check

shell-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm ubuntu /bin/zsh

test-local:
	chezmoi diff --source=./home

# The parallel post-apply suite keeps tests/idempotent.bats excluded as
# redundant defense behind that file's MMS_DISPOSABLE_HOME guard. The guard
# makes direct host runs inert, but the exclusion keeps this host-safe target
# from reaching the real apply commands at all. Use `make test-ubuntu` to run
# the full five-file suite against a disposable $$HOME.
#
# Second, sharper limit: these four files assert against the deployed $$HOME,
# and this target deliberately applies nothing. So it reports on whatever was
# last applied to this machine, NOT on the working checkout -- an edit under
# home/ that has not been applied is invisible here, and the run still goes
# green. `make test-ubuntu` applies the checkout first, which is why it is the
# answer for an unapplied edit. The echo below repeats this at the point of
# use, because a caveat that lives only in this comment reaches nobody.
test-suite: init-submodules
	@echo "NOTE: tests/idempotent.bats remains excluded behind its disposable-home guard."
	@echo "      Use make test-ubuntu to run those real apply tests safely."
	@echo "NOTE: asserts against the ALREADY-APPLIED ~/ , not this checkout."
	@echo "      An edit under home/ is not covered until it is applied."
	@echo "      To test an unapplied edit, use: make test-ubuntu"
	tests/run-post-apply.sh host-safe

test-docker: test-issues build-docker
	@echo "=== Running Ubuntu tests ==="
	docker compose -f docker/docker-compose.yml run --rm test-full

lint:
	@echo "=== Running shellcheck ==="
	find . -name "*.sh" -type f -not -path "./.git/*" -not -path "*/node_modules/*" | xargs shellcheck --severity=warning
	find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning
	find home -name "executable_*" -type f -exec sh -c 'for file do case "$$(head -n 1 "$$file")" in *python*) ;; *) shellcheck --severity=warning "$$file" || exit ;; esac; done' sh {} +

clean:
	docker compose -f docker/docker-compose.yml down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker image prune -f
