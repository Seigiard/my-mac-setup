.PHONY: help test-ubuntu test-local test-docker lint clean build-docker shell-ubuntu

# Default target
help:
	@echo "Chezmoi Dotfiles - Available commands:"
	@echo ""
	@echo "  make test-ubuntu    Run tests in Ubuntu Docker container"
	@echo "  make test-local     Run chezmoi diff on current machine (dry-run)"
	@echo "  make test-docker    Build and run full Docker test suite"
	@echo "  make lint           Run shellcheck on all scripts"
	@echo "  make shell-ubuntu   Open interactive shell in Ubuntu container"
	@echo "  make build-docker   Build Docker image without running tests"
	@echo "  make clean          Remove Docker containers and images"

# Build Docker image
build-docker:
	docker compose -f docker/docker-compose.yml build

# Run tests in Ubuntu Docker container
test-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm test

# Open interactive shell in Ubuntu container
shell-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm ubuntu /bin/zsh

# Run chezmoi diff on current machine (safe, no changes)
test-local:
	chezmoi diff --source=./home

# Run full Docker test suite
test-docker: build-docker
	@echo "=== Running Ubuntu tests ==="
	docker compose -f docker/docker-compose.yml run --rm test

# Lint all shell scripts
lint:
	@echo "=== Running shellcheck ==="
	find . -name "*.sh" -type f -not -path "./.git/*" | xargs shellcheck --severity=warning || true
	find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning || true

# Clean up Docker resources
clean:
	docker compose -f docker/docker-compose.yml down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker image prune -f
