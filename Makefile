.PHONY: help test-ubuntu test-local test-docker test-templates lint clean build-docker shell-ubuntu init-submodules

help:
	@echo "Chezmoi Dotfiles - Available commands:"
	@echo ""
	@echo "  make test-ubuntu      Run tests in Ubuntu Docker container"
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
	docker compose -f docker/docker-compose.yml run --rm test-quick /bin/bash -c \
		'set -e && cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/ && \
		chezmoi init --source=/home/testuser/.local/share/chezmoi --promptString name="Test User" --promptString email="test@example.com" && \
		bats tests/templates.bats'

shell-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm ubuntu /bin/zsh

test-local:
	chezmoi diff --source=./home

test-docker: build-docker
	@echo "=== Running Ubuntu tests ==="
	docker compose -f docker/docker-compose.yml run --rm test-full

lint:
	@echo "=== Running shellcheck ==="
	find . -name "*.sh" -type f -not -path "./.git/*" | xargs shellcheck --severity=warning || true
	find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning || true

clean:
	docker compose -f docker/docker-compose.yml down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker image prune -f
