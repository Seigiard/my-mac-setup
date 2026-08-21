---
status: done
---

# Chezmoi Testing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add bats-assert/bats-file libraries, refactor smoke tests for readability, add template/script/platform test suites for cross-platform regression protection.

**Architecture:** Extend existing bats test structure with git submodules for bats libraries. Add 3 new test files (templates, scripts, platform). Update CI, Docker, and Makefile to support the new tests.

**Tech Stack:** bats-core, bats-support, bats-assert, bats-file, chezmoi execute-template, GitHub Actions, Docker Compose

---

### Task 1: Add bats library git submodules

**Files:**
- Create: `tests/helpers/bats-libs/` (directory via submodules)

**Step 1: Add bats-support submodule**

```bash
cd /Users/seigiard/Projects/my-mac-setup
git submodule add https://github.com/bats-core/bats-support.git tests/helpers/bats-libs/bats-support
```

**Step 2: Add bats-assert submodule**

```bash
git submodule add https://github.com/bats-core/bats-assert.git tests/helpers/bats-libs/bats-assert
```

**Step 3: Add bats-file submodule**

```bash
git submodule add https://github.com/bats-core/bats-file.git tests/helpers/bats-libs/bats-file
```

**Step 4: Verify submodules are registered**

```bash
git submodule status
```

Expected: Three submodule entries with commit hashes.

**Step 5: Commit**

```bash
git add .gitmodules tests/helpers/bats-libs
git commit -m "$(cat <<'EOF'
Add bats-support, bats-assert, bats-file as git submodules

These libraries provide readable assertions (assert_success,
assert_file_exists, etc.) for bats tests.
EOF
)"
```

---

### Task 2: Extend common.bash with bats-libs loading and new helpers

**Files:**
- Modify: `tests/helpers/common.bash` (EXTEND, not replace)
- Create: `tests/helpers_test.bats` (kept permanently for regression)

**Merge strategy:** Preserve all existing functions (command_exists, get_os, is_macos, is_linux, CHEZMOI_SOURCE). Add bats-libs loading and new helpers.

**Step 1: Write the test to verify helpers load correctly**

Create `tests/helpers_test.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/common'

@test "bats-assert is loaded (assert_success available)" {
  run true
  assert_success
}

@test "bats-file is loaded (assert_file_exists available)" {
  assert_file_exists /etc/hosts
}

@test "render_template helper is available" {
  run type render_template
  assert_success
}

@test "assert_no_template_markers helper is available" {
  run type assert_no_template_markers
  assert_success
}

@test "skip_if_no_chezmoi helper works when chezmoi present" {
  if ! command -v chezmoi >/dev/null 2>&1; then
    skip "chezmoi not installed"
  fi
  skip_if_no_chezmoi
}

@test "existing helpers preserved: command_exists works" {
  run command_exists bash
  assert_success
}

@test "existing helpers preserved: get_os returns valid value" {
  run get_os
  assert_success
  [[ "$output" == "darwin" || "$output" == "linux" || "$output" == "unknown" ]]
}
```

**Step 2: Run test to verify it fails**

```bash
bats tests/helpers_test.bats
```

Expected: FAIL — `assert_success` command not found (bats-assert not loaded yet).

**Step 3: Update common.bash — EXTEND existing file**

The updated `tests/helpers/common.bash` preserves all existing code and adds bats-libs loading + new helpers:

```bash
# Common test helpers for bats tests

# Resolve helpers directory (where this file lives)
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard: verify bats-libs are present (submodules initialized)
if [[ ! -f "${HELPERS_DIR}/bats-libs/bats-support/load.bash" ]]; then
  echo "ERROR: bats-libs not found. Run: git submodule update --init --recursive" >&2
  return 1
fi

# Load bats libraries
load "${HELPERS_DIR}/bats-libs/bats-support/load"
load "${HELPERS_DIR}/bats-libs/bats-assert/load"
load "${HELPERS_DIR}/bats-libs/bats-file/load"

# Source directory for chezmoi (auto-detect from chezmoi config or use default)
if command -v chezmoi >/dev/null 2>&1; then
  CHEZMOI_SOURCE="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
else
  CHEZMOI_SOURCE="${CHEZMOI_SOURCE:-$HOME/.local/share/chezmoi}"
fi
export CHEZMOI_SOURCE

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

is_macos() {
  [[ "$(get_os)" == "darwin" ]]
}

is_linux() {
  [[ "$(get_os)" == "linux" ]]
}

skip_if_no_chezmoi() {
  if ! command_exists chezmoi; then
    skip "chezmoi not installed"
  fi
}

# Render a chezmoi template file and print the output.
#
# Specification:
#   Input:  One argument — path to a .tmpl file
#   Method: chezmoi execute-template < "$template_file"
#   Output: Rendered template content on stdout
#   Prereq: chezmoi init must have been run (for data context)
#   Errors: Returns chezmoi's exit code; callers use `run render_template ...` + assert_success
#   Note:   Error messages won't include source filename (stdin)
render_template() {
  local template_file="$1"
  chezmoi execute-template < "$template_file"
}

# Assert that a file contains no unresolved chezmoi template markers.
#
# Specification:
#   Input:   Path to a rendered (non-template) file
#   Method:  run grep -n '{{.*}}' "$file" then assert_failure (no args)
#   Success: grep finds NO matches (exit 1) → assert_failure passes
#   Failure: grep finds matches (exit 0) → assert_failure fails; $output has matched lines
#   Caveat:  False-positive on files with legitimate {{ (JS, GHA). Current templates
#            produce shell/config only, so this is safe. Exclude future JS/GHA files.
assert_no_template_markers() {
  local file="$1"
  run grep -n '{{.*}}' "$file"
  assert_failure
}
```

**Step 4: Run test to verify it passes**

```bash
bats tests/helpers_test.bats
```

Expected: All 7 tests PASS.

**Step 5: Commit**

```bash
git add tests/helpers/common.bash tests/helpers_test.bats
git commit -m "$(cat <<'EOF'
Extend common.bash: load bats-assert/bats-file, add template helpers

New helpers: render_template, assert_no_template_markers, skip_if_no_chezmoi.
All bats libraries auto-loaded via common.bash with missing-submodule guard.
Existing helpers (command_exists, get_os, is_macos, is_linux) preserved.
EOF
)"
```

---

### Task 3: Create templates.bats

**Files:**
- Create: `tests/templates.bats`

**Prerequisite:** `chezmoi init --source=./home` with CHEZMOI_NAME/CHEZMOI_EMAIL env vars.

**Step 1: Write the template tests**

Create `tests/templates.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/common'

setup() {
  skip_if_no_chezmoi
  export CHEZMOI_NAME="Test User"
  export CHEZMOI_EMAIL="test@example.com"
}

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE"
}

# ===========================================
# .chezmoi.yaml.tmpl
# ===========================================

@test "chezmoi config template renders with env vars" {
  run chezmoi execute-template < "$CHEZMOI_SOURCE/.chezmoi.yaml.tmpl"
  assert_success
  assert_output --partial "name:"
  assert_output --partial "email:"
}

# ===========================================
# dot_gitconfig.tmpl
# ===========================================

@test "gitconfig template renders successfully" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_success
}

@test "gitconfig template contains user name" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_output --partial "name = "
}

@test "gitconfig template contains user email" {
  run render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl"
  assert_output --partial "email = "
}

@test "gitconfig template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_gitconfig.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# dot_zshenv.tmpl
# ===========================================

@test "zshenv template renders without op in PATH" {
  local clean_path=""
  local -a path_dirs
  IFS=':' read -ra path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [[ -d "$dir" ]] && [[ -x "$dir/op" ]] && continue
    clean_path="${clean_path:+$clean_path:}$dir"
  done
  PATH="$clean_path" run render_template "$CHEZMOI_SOURCE/dot_zshenv.tmpl"
  assert_success
}

@test "zshenv template output has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_zshenv.tmpl" > "$BATS_TEST_TMPFILE" || true
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}

# ===========================================
# dot_zshrc.tmpl
# ===========================================

@test "zshrc template renders successfully" {
  run render_template "$CHEZMOI_SOURCE/dot_zshrc.tmpl"
  assert_success
}

@test "zshrc template has no unresolved markers" {
  BATS_TEST_TMPFILE="$(mktemp)"
  render_template "$CHEZMOI_SOURCE/dot_zshrc.tmpl" > "$BATS_TEST_TMPFILE"
  assert_no_template_markers "$BATS_TEST_TMPFILE"
}
```

**Step 2: Run tests to verify**

```bash
bats tests/templates.bats
```

Expected: All pass.

**Step 3: Commit**

```bash
git add tests/templates.bats
git commit -m "$(cat <<'EOF'
Add templates.bats: verify chezmoi template rendering

Tests .chezmoi.yaml, .gitconfig, .zshenv, .zshrc templates.
Checks for unresolved {{ }} markers and correct variable substitution.
Verifies 1Password guard works when op not in PATH.
Uses teardown() for tmpfile cleanup on assertion failure.
EOF
)"
```

---

### Task 4: Create scripts.bats

**Files:**
- Create: `tests/scripts.bats`

**Scope:** Syntax and structure validation ONLY. Scripts are NOT executed.

**Step 1: Write the script tests**

Create `tests/scripts.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/common'

teardown() {
  [[ -n "${BATS_TEST_TMPFILE:-}" ]] && rm -f "$BATS_TEST_TMPFILE"
}

# ===========================================
# install-packages script
# ===========================================

@test "install-packages script renders as valid bash" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"

  BATS_TEST_TMPFILE="$(mktemp /tmp/install-packages-XXXXXX.sh)"
  chezmoi execute-template < "$script" > "$BATS_TEST_TMPFILE"
  run bash -n "$BATS_TEST_TMPFILE"
  assert_success
}

@test "install-packages script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run grep -q "set -e" "$script"
  assert_success
}

@test "install-packages template has no rendering errors" {
  skip_if_no_chezmoi
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/run_onchange_after_install-packages.sh.tmpl"
  [[ -f "$script" ]] || skip "install-packages script not found at $script"
  run chezmoi execute-template < "$script"
  assert_success
}

# ===========================================
# macOS tunes script
# ===========================================

@test "macos-tunes script exists in darwin-specific directory" {
  assert_file_exists "$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
}

@test "macos-tunes script is valid bash" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run bash -n "$script"
  assert_success
}

@test "macos-tunes script uses set -e" {
  local script="$CHEZMOI_SOURCE/.chezmoiscripts/darwin/run_once_after_macos-tunes.sh"
  run grep -q "set -e" "$script"
  assert_success
}

@test "darwin scripts excluded from managed list on Linux" {
  is_linux || skip "Only relevant on Linux"
  skip_if_no_chezmoi
  run chezmoi managed
  refute_output --partial "run_once_after_macos-tunes"
}
```

**Step 2: Run tests**

```bash
bats tests/scripts.bats
```

Expected: All pass.

**Step 3: Commit**

```bash
git add tests/scripts.bats
git commit -m "$(cat <<'EOF'
Add scripts.bats: validate chezmoi run scripts

Checks bash syntax (bash -n on rendered output via named tmpfile),
set -e usage, and template rendering. Verifies .chezmoiignore excludes
darwin scripts on Linux. No runtime execution of scripts.
Uses teardown() for tmpfile cleanup.
EOF
)"
```

---

### Task 5: Create platform.bats

**Files:**
- Create: `tests/platform.bats`

**Verified:** `chezmoi managed` outputs target names (`.hammerspoon`, `Library` without trailing slash).

**Step 1: Write the platform tests**

Create `tests/platform.bats`:

```bash
#!/usr/bin/env bats

load 'helpers/common'

setup() {
  skip_if_no_chezmoi
}

# ===========================================
# .chezmoiignore platform filtering
# ===========================================

@test "chezmoiignore filters macOS files on Linux" {
  is_linux || skip "Only relevant on Linux"
  run chezmoi managed
  refute_output --partial ".hammerspoon"
  refute_output --partial "Library"
  refute_output --partial ".config/ghostty"
  refute_output --partial ".config/karabiner"
  refute_output --partial ".config/zed"
}

@test "chezmoiignore includes macOS files on macOS" {
  is_macos || skip "Only relevant on macOS"
  run chezmoi managed
  assert_output --partial ".hammerspoon"
  assert_output --partial ".config/ghostty"
  assert_output --partial ".config/karabiner"
  assert_output --partial ".config/zed"
}

# ===========================================
# Platform-specific file presence after apply
# ===========================================

@test "hammerspoon absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_file_not_exists "$HOME/.hammerspoon"
}

@test "Library absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_file_not_exists "$HOME/Library"
}

@test "ghostty config absent on Linux" {
  is_linux || skip "Only relevant on Linux"
  assert_file_not_exists "$HOME/.config/ghostty"
}
```

**Step 2: Run tests**

```bash
bats tests/platform.bats
```

Expected: Platform-specific tests run on the current OS, others skip.

**Step 3: Commit**

```bash
git add tests/platform.bats
git commit -m "$(cat <<'EOF'
Add platform.bats: cross-platform chezmoi validation

Tests .chezmoiignore filtering (verified: chezmoi managed outputs
target names) and platform-specific file presence.
Each test guarded with is_linux/is_macos skip directives.
EOF
)"
```

---

### Task 6: Update CI workflow

**Files:**
- Modify: `.github/workflows/test-dotfiles.yml`

**Key changes:**
- `submodules: recursive` in checkout
- Job-level `env:` for CHEZMOI_NAME/CHEZMOI_EMAIL (non-interactive init everywhere)
- `chezmoi init` before template tests
- Staged execution within single jobs (GHA default stops on step failure)

**Step 1: Update the workflow**

Replace `.github/workflows/test-dotfiles.yml` with:

```yaml
name: Test Dotfiles

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  CHEZMOI_NAME: "Test User"
  CHEZMOI_EMAIL: "test@example.com"

jobs:
  test-ubuntu:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install zsh
        run: sudo apt-get update && sudo apt-get install -y zsh

      - name: Install chezmoi
        run: sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin

      - name: Add chezmoi to PATH
        run: echo "$HOME/.local/bin" >> $GITHUB_PATH

      - name: Install bats
        run: |
          sudo apt-get update
          sudo apt-get install -y bats

      # Stage 1: Initialize chezmoi (non-interactive via env vars)
      - name: Initialize chezmoi
        run: chezmoi init --source=./home

      # Stage 2: Validate test infrastructure
      - name: Validate test infrastructure
        run: bats tests/helpers_test.bats

      # Stage 3: Fast pre-check gate (no apply needed)
      - name: Run template tests (pre-apply gate)
        run: bats tests/templates.bats

      # Stage 4: Apply dotfiles
      - name: Apply dotfiles (dry-run first)
        run: chezmoi diff --source=./home || true

      - name: Apply dotfiles
        run: chezmoi apply --source=./home --verbose

      # Stage 5: Post-apply tests
      - name: Run post-apply tests
        run: bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats

  test-macos:
    runs-on: macos-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install chezmoi
        run: brew install chezmoi

      - name: Install bats
        run: brew install bats-core

      - name: Initialize chezmoi
        run: chezmoi init --source=./home

      - name: Validate test infrastructure
        run: bats tests/helpers_test.bats

      - name: Run template tests (pre-apply gate)
        run: bats tests/templates.bats

      - name: Apply dotfiles (dry-run first)
        run: chezmoi diff --source=./home || true

      - name: Apply dotfiles
        run: chezmoi apply --source=./home --verbose

      - name: Run post-apply tests
        run: bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats

  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck

      - name: Run shellcheck on scripts
        run: |
          find . -name "*.sh" -type f -not -path "./.git/*" | xargs shellcheck --severity=warning || true
          find home -name "run_*" -type f 2>/dev/null | xargs shellcheck --severity=warning || true
```

**Step 2: Verify YAML is valid**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-dotfiles.yml'))"
```

Expected: No output (valid YAML).

**Step 3: Commit**

```bash
git add .github/workflows/test-dotfiles.yml
git commit -m "$(cat <<'EOF'
Update CI: staged test execution with template pre-check gate

Adds submodules: recursive, job-level CHEZMOI_NAME/EMAIL env vars
for non-interactive init, and staged execution:
init → helpers → templates (gate) → apply → post-apply tests.
EOF
)"
```

---

### Task 7: Update Docker and Makefile

**Files:**
- Modify: `docker/docker-compose.yml`
- Modify: `Makefile`

**Step 1: Update docker-compose.yml**

```yaml
services:
  # Interactive shell for debugging
  ubuntu:
    build:
      context: .
      dockerfile: Dockerfile.ubuntu
    volumes:
      - ../home:/home/testuser/dotfiles:ro
      - ../tests:/home/testuser/tests:ro
    environment:
      - CHEZMOI_NAME=Test User
      - CHEZMOI_EMAIL=test@example.com
      - HOMEBREW_NO_AUTO_UPDATE=1
      - HOMEBREW_NO_INSTALL_CLEANUP=1
    stdin_open: true
    tty: true

  # Full test with package installation
  test-full:
    build:
      context: .
      dockerfile: Dockerfile.ubuntu
    volumes:
      - ../home:/home/testuser/dotfiles:ro
      - ../tests:/home/testuser/tests:ro
    environment:
      - CHEZMOI_NAME=Test User
      - CHEZMOI_EMAIL=test@example.com
      - HOMEBREW_NO_AUTO_UPDATE=1
      - HOMEBREW_NO_INSTALL_CLEANUP=1
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -e
        echo "=== Copying dotfiles to chezmoi source ==="
        (cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/)

        echo "=== Initializing chezmoi ==="
        chezmoi init --source=/home/testuser/.local/share/chezmoi \
          --promptString name="Test User" \
          --promptString email="test@example.com"

        echo "=== Validating test infrastructure ==="
        bats tests/helpers_test.bats

        echo "=== Running template tests (pre-apply gate) ==="
        bats tests/templates.bats

        echo "=== Applying dotfiles (with package installation) ==="
        chezmoi apply --source=/home/testuser/.local/share/chezmoi --verbose

        echo "=== Running post-apply tests ==="
        bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats

        echo "=== All done! ==="

  # Quick test (no package installation, just config files)
  test-quick:
    build:
      context: .
      dockerfile: Dockerfile.ubuntu
    volumes:
      - ../home:/home/testuser/dotfiles:ro
      - ../tests:/home/testuser/tests:ro
    environment:
      - CHEZMOI_NAME=Test User
      - CHEZMOI_EMAIL=test@example.com
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -e
        (cd /home/testuser/dotfiles && cp -r . /home/testuser/.local/share/chezmoi/)
        chezmoi init --source=/home/testuser/.local/share/chezmoi \
          --promptString name="Test User" \
          --promptString email="test@example.com"
        bats tests/helpers_test.bats
        bats tests/templates.bats
        chezmoi apply --source=/home/testuser/.local/share/chezmoi --verbose
        bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats
```

**Step 2: Update Makefile**

Replace full file:

```makefile
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
```

**Step 3: Verify Makefile targets list**

```bash
make help
```

Expected: Shows all targets including `test-templates`.

**Step 4: Commit**

```bash
git add docker/docker-compose.yml Makefile
git commit -m "$(cat <<'EOF'
Update Docker and Makefile: staged tests, submodule init guard

Docker services use staged tests with CHEZMOI_NAME/EMAIL env vars.
Makefile adds init-submodules prerequisite for all Docker targets.
build-docker auto-initializes submodules if bats-libs missing.
EOF
)"
```

---

### Task 8: Refactor smoke.bats to use bats-assert

**Files:**
- Modify: `tests/smoke.bats`

**Note:** This is done LAST so new test infrastructure is proven stable first.

**Step 1: Refactor smoke.bats**

Replace the full contents of `tests/smoke.bats` with:

```bash
#!/usr/bin/env bats

load 'helpers/common'

# ===========================================
# Core tools (must exist on both platforms)
# ===========================================

@test "zsh is installed" {
  run command -v zsh
  assert_success
}

@test "git is installed" {
  run command -v git
  assert_success
}

@test "curl is installed" {
  run command -v curl
  assert_success
}

# ===========================================
# Chezmoi-managed files exist
# ===========================================

@test ".zshrc exists" {
  assert_file_exists "$HOME/.zshrc"
}

@test ".aliases exists" {
  assert_file_exists "$HOME/.aliases"
}

@test ".gitconfig exists" {
  assert_file_exists "$HOME/.gitconfig"
}

@test ".editorconfig exists" {
  assert_file_exists "$HOME/.editorconfig"
}

@test "starship.toml exists" {
  assert_file_exists "$HOME/.config/starship.toml"
}

# ===========================================
# Yazi configuration
# ===========================================

@test "yazi config exists" {
  assert_file_exists "$HOME/.config/yazi"
}

# ===========================================
# Claude Code configuration
# ===========================================

@test ".claude directory exists" {
  assert_file_exists "$HOME/.claude"
}

@test ".claude/CLAUDE.md exists" {
  assert_file_exists "$HOME/.claude/CLAUDE.md"
}

# ===========================================
# macOS-only configs (skipped on Linux)
# ===========================================

@test "hammerspoon config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_file_exists "$HOME/.hammerspoon"
}

@test "ghostty config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_file_exists "$HOME/.config/ghostty"
}

@test "karabiner config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_file_exists "$HOME/.config/karabiner"
}

@test "zed config exists (macOS only)" {
  is_macos || skip "Not on macOS"
  assert_file_exists "$HOME/.config/zed"
}

# ===========================================
# Optional tools (installed via package manager)
# ===========================================

@test "starship is available (if installed)" {
  command_exists starship || skip "starship not installed"
  run starship --version
  assert_success
}

@test "bat is available (if installed)" {
  command_exists bat || skip "bat not installed"
  run bat --version
  assert_success
}

@test "eza is available (if installed)" {
  command_exists eza || skip "eza not installed"
  run eza --version
  assert_success
}

@test "fd is available (if installed)" {
  command_exists fd || skip "fd not installed"
  run fd --version
  assert_success
}

@test "fzf is available (if installed)" {
  command_exists fzf || skip "fzf not installed"
  run fzf --version
  assert_success
}

@test "ripgrep is available (if installed)" {
  command_exists rg || skip "ripgrep not installed"
  run rg --version
  assert_success
}

@test "delta is available (if installed)" {
  command_exists delta || skip "delta not installed"
  run delta --version
  assert_success
}

@test "yazi is available (if installed)" {
  command_exists yazi || skip "yazi not installed"
  run yazi --version
  assert_success
}

@test "lazygit is available (if installed)" {
  command_exists lazygit || skip "lazygit not installed"
  run lazygit --version
  assert_success
}

@test "zoxide is available (if installed)" {
  command_exists zoxide || skip "zoxide not installed"
  run zoxide --version
  assert_success
}

@test "mise is available (if installed)" {
  command_exists mise || skip "mise not installed"
  run mise --version
  assert_success
}
```

**Step 2: Run the refactored tests**

```bash
bats tests/smoke.bats
```

Expected: Same results as before.

**Step 3: Commit**

```bash
git add tests/smoke.bats
git commit -m "$(cat <<'EOF'
Refactor smoke.bats to use bats-assert and bats-file

Replaces manual [[ ]] checks with assert_success, assert_file_exists.
Cleaner skip patterns using || skip instead of if/fi blocks.
EOF
)"
```

---

### Task 9: Run full test suite and verify

**Files:** None (verification only)

**Definition of done:** All bats tests pass. Every test file contains at least one passing (non-skipped) test. Minimum 20 total test cases across all files.

**Step 1: Initialize submodules (if not done)**

```bash
git submodule update --init --recursive
```

**Step 2: Ensure chezmoi is initialized**

```bash
export CHEZMOI_NAME="Test User"
export CHEZMOI_EMAIL="test@example.com"
chezmoi init --source=./home
```

**Step 3: Run staged verification**

```bash
bats tests/helpers_test.bats && \
bats tests/templates.bats && \
echo "Pre-apply gate passed" && \
bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats
```

Expected: All tests pass (some skip based on platform/tools).

**Step 4: Verify test count gate**

```bash
total=$(bats tests/ --formatter tap 2>/dev/null | grep -c '^ok')
echo "Total passing tests: $total"
[[ $total -ge 20 ]] && echo "PASS: minimum test count met" || echo "FAIL: fewer than 20 passing tests"
```

Expected: At least 20 passing tests across all files.

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | Add bats-libs submodules | `.gitmodules`, `tests/helpers/bats-libs/` |
| 2 | Extend common.bash + helpers_test.bats | `tests/helpers/common.bash`, `tests/helpers_test.bats` |
| 3 | Create templates.bats | `tests/templates.bats` |
| 4 | Create scripts.bats | `tests/scripts.bats` |
| 5 | Create platform.bats | `tests/platform.bats` |
| 6 | Update CI workflow | `.github/workflows/test-dotfiles.yml` |
| 7 | Update Docker + Makefile | `docker/docker-compose.yml`, `Makefile` |
| 8 | Refactor smoke.bats (last) | `tests/smoke.bats` |
| 9 | Final verification | (staged run, definition of done) |

## Changes from v2 (addressing iteration 2 review feedback)

1. **Verified `chezmoi managed` output format** — confirmed target names (`.hammerspoon`, `Library` without trailing slash). Fixed `refute_output --partial "Library/"` → `"Library"` in platform.bats.
2. **Non-interactive chezmoi init across ALL suites** — CHEZMOI_NAME/CHEZMOI_EMAIL set at job-level env in CI, environment block in Docker, and documented as local prerequisite.
3. **Specified render_template contract** — full specification in common.bash comments: input, method, output, prerequisites, error behavior, limitations.
4. **Added tmpfile cleanup** — teardown() in templates.bats and scripts.bats cleans BATS_TEST_TMPFILE on assertion failure.
5. **Documented false-positive risk for {{ }} detection** — assert_no_template_markers specification notes caveat about JS/GHA files. Currently safe (all templates produce shell/config).
6. **Enforced submodule init in Docker/Makefile** — init-submodules prerequisite target in Makefile. common.bash guard fails with clear error if bats-libs missing.
7. **Verified dot_gitconfig.tmpl exists** — confirmed at `home/dot_gitconfig.tmpl`.
8. **Named tmpfiles in scripts.bats** — `mktemp /tmp/install-packages-XXXXXX.sh` for meaningful bash -n error messages.
9. **PATH loop safety** — added `[[ -d "$dir" ]]` check before `-x` test in zshenv template test.

## Changes from v3 (addressing iteration 3 review feedback)

1. **CRITICAL: Verified `chezmoi execute-template` resolves ALL template data and functions** — empirically confirmed by running actual commands:
   - `.chezmoi.os` → `darwin`, `.chezmoi.hostname` → actual hostname
   - `env "CHEZMOI_NAME"` → reads env vars correctly
   - `lookPath "git"` → `/usr/bin/git`, `lookPath "op"` → `/opt/homebrew/bin/op`
   - `include`, `stat`, `joinPath` — all work after `chezmoi init`
   - Full template rendering of `dot_gitconfig.tmpl` produces correct output with substitutions
2. **IMPORTANT: Verified CHEZMOI_SOURCE path resolution** — `chezmoi source-path` after `chezmoi init --source=./home` returns absolute path (`/Users/.../my-mac-setup/home`), not relative.
3. **MINOR: PATH filtering uses `read -ra`** — replaced IFS-based loop with `IFS=':' read -ra path_dirs <<< "$PATH"` for safe splitting of entries with spaces.
4. **MINOR: Task 9 concrete verification gate** — added minimum test count assertion (>= 20 passing tests) as enforceable definition of done.
