.PHONY: help test-issues test-ubuntu test-local test-suite test-docker test-templates test-pi-agents-local test-pi-herdr-worktree-identity lint clean build-docker shell-ubuntu

help:
	@echo "Chezmoi Dotfiles - Available commands:"
	@echo ""
	@echo "  make test-issues      Validate repository issues and run their Python tests"
	@echo "  make test-ubuntu      Run tests in Ubuntu Docker container"
	@echo "  make test-suite       Run the post-apply suite in parallel (host-safe files)"
	@echo "  make test-templates   Run template tests in Docker (may rebuild images)"
	@echo "  make test-pi-agents-local  Run focused Pi local-instructions extension tests"
	@echo "  make test-pi-herdr-worktree-identity  Run focused Pi worktree-identity extension tests"
	@echo "  make test-local       Diff checkout source against current home (dry-run)"
	@echo "  make test-docker      Build and run full Docker test suite"
	@echo "  make lint             Run shellcheck on all scripts"
	@echo "  make shell-ubuntu     Open interactive shell in Ubuntu container"
	@echo "  make build-docker     Build Docker image without running tests"
	@echo "  make clean            Remove Docker containers and images"

test-issues:
	python3 scripts/issues validate
	python3 -m unittest discover -s tests -p 'test_*.py'

build-docker:
	docker compose -f docker/docker-compose.yml build

test-ubuntu: test-issues build-docker
	docker compose -f docker/docker-compose.yml run --rm test-ubuntu

test-templates: test-issues build-docker
	docker compose -f docker/docker-compose.yml run --rm -T test-ubuntu \
		'set -e && (cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/) && \
		tests/helpers/chezmoi-unattended --profile full-fixture -- init --source=/home/testuser/.local/share/chezmoi --promptString name="Test User" --promptString email="test@example.com" && \
		tests/lib/bashunit -j 8 tests/bashunit/templates_test.sh'

test-pi-agents-local:
	bun test tests/pi-agents-local-extension.test.ts

test-pi-herdr-worktree-identity:
	bun test tests/pi-herdr-worktree-identity.test.ts

shell-ubuntu: build-docker
	docker compose -f docker/docker-compose.yml run --rm ubuntu /bin/zsh

test-local:
	@MMS_CHEZMOI_UNATTENDED=1 tests/helpers/chezmoi-unattended --profile host-partial -- diff --source=./home

# This host-safe target excludes tests/bashunit/idempotent_test.sh and applies
# nothing. It reports on the already-applied $$HOME, not the working checkout.
test-suite:
	@echo "NOTE: tests/bashunit/idempotent_test.sh remains excluded behind its disposable-home guard."
	@echo "NOTE: asserts against the ALREADY-APPLIED ~/ , not this checkout."
	tests/run-post-apply.sh host-safe

test-docker: test-issues build-docker
	@echo "=== Running Ubuntu tests ==="
	docker compose -f docker/docker-compose.yml run --rm test-full

# tests/bashunit/*_test.sh: converted test bodies; shellcheck them when the
# vocabulary is nativized.
lint:
	@echo "=== Running shellcheck ==="
	find . -name "*.sh" -type f -not -path "./.git/*" -not -path "./.worktrees/*" -not -path "*/node_modules/*" -not -path "./.context/*" -not -path "./tests/bashunit/*_test.sh" | xargs shellcheck --severity=warning
	find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning
	find home -name "executable_*" -type f -not -name "*.py" 2>/dev/null | xargs shellcheck --severity=warning
	shellcheck --severity=warning tests/helpers/chezmoi-unattended
	python3 scripts/check_bats_assertions.py tests

clean:
	docker compose -f docker/docker-compose.yml down --rmi local --volumes --remove-orphans 2>/dev/null || true
	docker image prune -f
