.PHONY: help test-ubuntu test-local test-suite test-docker test-templates lint clean build-docker shell-ubuntu init-submodules

help:
	@echo "Chezmoi Dotfiles - Available commands:"
	@echo ""
	@echo "  make test-ubuntu      Run tests in Ubuntu Docker container"
	@echo "  make test-suite       Run the post-apply suite in parallel (host-safe files)"
	@echo "  make test-templates   Run template tests only (fast, no apply)"
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

build-docker: init-submodules
	docker compose -f docker/docker-compose.yml build

test-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm test-quick

test-templates: build-docker
	docker compose -f docker/docker-compose.yml run --rm -T test-quick \
		'set -e && (cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/) && \
		chezmoi init --source=/home/testuser/.local/share/chezmoi --promptString name="Test User" --promptString email="test@example.com" && \
		bats tests/templates.bats'

shell-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm ubuntu /bin/zsh

test-local:
	chezmoi diff --source=./home

# The parallel post-apply suite, minus tests/idempotent.bats: those four tests
# run a real `chezmoi apply` with no --destination, so on a workstation they
# deploy the checkout over the developer's live dotfiles
# (docs/issues/2026-08-21-004). The full five-file suite runs in CI and in
# Docker, where $$HOME is disposable -- use `make test-ubuntu` for that.
test-suite: init-submodules
	bats --jobs 8 --no-parallelize-across-files tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats

test-docker: build-docker
	@echo "=== Running Ubuntu tests ==="
	docker compose -f docker/docker-compose.yml run --rm test-full

lint:
	@echo "=== Running shellcheck ==="
	find . -name "*.sh" -type f -not -path "./.git/*" -not -path "*/node_modules/*" | xargs shellcheck --severity=warning
	find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning
	find home -name "executable_*" -type f -not -name "*.py" 2>/dev/null | xargs shellcheck --severity=warning

clean:
	docker compose -f docker/docker-compose.yml down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker image prune -f
