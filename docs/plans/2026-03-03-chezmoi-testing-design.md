# Chezmoi Testing Design

**Date:** 2026-03-03
**Goal:** Cross-platform regression protection + confidence in changes

## Decision

Approach B: Modular structure with bats-assert/bats-file libraries. Extends existing tests, adds template/script/platform validation.

## Structure

```
tests/
├── helpers/
│   ├── common.bash               # extended: load bats-libs, new helpers
│   └── bats-libs/                # git submodules
│       ├── bats-support/
│       ├── bats-assert/
│       └── bats-file/
├── smoke.bats                    # refactored to use assert_*
├── idempotent.bats               # unchanged
├── helpers_test.bats             # validates bats-libs loading + helpers
├── templates.bats                # NEW: .tmpl output verification
├── scripts.bats                  # NEW: run_once/run_onchange scripts
└── platform.bats                 # NEW: cross-platform checks
```

## Verified Facts (confirmed by running actual commands)

- `chezmoi managed` outputs **target names** (`.hammerspoon`, `.config/ghostty`, `Library`) — NOT source names
- `dot_gitconfig.tmpl` exists at `home/dot_gitconfig.tmpl`
- `.chezmoiignore` uses `{{ if ne .chezmoi.os "darwin" }}` to exclude macOS files on Linux
- `run_onchange_after_install-packages.sh.tmpl` does NOT have SKIP_PACKAGE_INSTALL support
- `run_once_after_macos-tunes.sh` is excluded on Linux via `.chezmoiignore` (`.chezmoiscripts/darwin/**`)
- **`chezmoi execute-template` from stdin resolves ALL template data and functions after `chezmoi init`:**
  - `.chezmoi.os` → `darwin` / `linux`
  - `.chezmoi.hostname` → actual hostname
  - `env "CHEZMOI_NAME"` → reads environment variable
  - `lookPath "git"` → `/usr/bin/git` (finds binaries in PATH)
  - `lookPath "op"` → finds 1Password CLI (or empty if absent)
  - `include "dot_aliases"` → reads files from chezmoi source
  - `stat`, `joinPath` → work correctly
- **`chezmoi source-path` returns absolute path** after `chezmoi init --source=./home` → `/Users/seigiard/Projects/my-mac-setup/home` (correct absolute path, not relative)

## Test Categories

### smoke.bats (refactor — last task)

Same checks, migrated to bats-assert for readable output:
- Core tools: zsh, git, curl
- Chezmoi-managed files: .zshrc, .aliases, .gitconfig, .editorconfig, starship.toml, .claude/
- macOS-only configs: hammerspoon, ghostty, karabiner, zed (skip on Linux)
- Optional tools: starship, bat, eza, fd, fzf, ripgrep, delta, yazi, lazygit, zoxide, mise

### idempotent.bats (unchanged)

Already solid: apply twice, verify diff empty, chezmoi verify.

### helpers_test.bats (retained for regression)

Validates bats-libs loading and custom helper functions. Kept permanently — not scaffolding.

### templates.bats (new)

**Prerequisite:** `chezmoi init --source=./home` with CHEZMOI_NAME/CHEZMOI_EMAIL env vars must be run before these tests.

- `chezmoi execute-template` for each .tmpl file
- Verify .zshenv has no unresolved `{{ }}` markers
- Verify .gitconfig substitutes name/email correctly
- Verify .chezmoi.yaml generates from CHEZMOI_NAME/CHEZMOI_EMAIL env vars
- Verify templates don't fail without `op` in PATH (1Password guard)
- Tmpfile cleanup via teardown() to prevent orphans on assertion failure

### scripts.bats (new)

Syntax and structure validation only — scripts are NOT executed:
- `bash -n` on rendered template output saved to named tmpfile (not pipe)
- `set -e` presence check
- Template rendering (produces valid bash)
- `.chezmoiignore` correctly excludes `.chezmoiscripts/darwin/**` on Linux
- Tmpfile cleanup via teardown()

Note: `SKIP_PACKAGE_INSTALL` env var does NOT exist in install-packages.sh.tmpl. Scripts.bats validates syntax/structure, not runtime behavior.

### platform.bats (new)

Verified: `chezmoi managed` outputs target names (`.hammerspoon`, not `dot_hammerspoon`). Assertions use these confirmed formats:
- `.hammerspoon` (not `dot_hammerspoon`)
- `.config/ghostty` (not `private_dot_config/ghostty`)
- `Library` (not `Library/` — no trailing slash)

Tests:
- .chezmoiignore correctly filters macOS-only files on Linux
- Hammerspoon/Ghostty/Karabiner/Zed configs present only on macOS
- Library not applied on Linux
- Each test uses `is_linux || skip` or `is_macos || skip` — runs only on its target OS

## Helpers (common.bash extensions)

**Merge strategy: extend existing file, preserve all current functions.**

Existing functions retained as-is:
- `command_exists(cmd)` — check if a command exists
- `get_os()` — returns "darwin", "linux", or "unknown"
- `is_macos()` / `is_linux()` — platform checks
- `CHEZMOI_SOURCE` auto-detection

New additions:
- Bats-libs auto-load with guard: check bats-support/load.bash exists, fail with clear error if missing
- `render_template(file)` — see specification below
- `skip_if_no_chezmoi` — skip if chezmoi not installed
- `assert_no_template_markers(file)` — see specification below

### render_template specification

- **Input:** Accepts one argument: path to a .tmpl file
- **Method:** `chezmoi execute-template < "$template_file"`
- **Output:** Rendered template content on stdout
- **Prerequisite:** Requires `chezmoi init` to have been run (for .chezmoi.os, .chezmoi.hostname, custom data resolution)
- **Error behavior:** Returns chezmoi's exit code. Callers should use `run render_template ...` and check `assert_success`
- **Limitation:** Error messages from chezmoi won't include the source filename (stdin has no name)

### assert_no_template_markers specification

- **Input:** Path to a rendered (non-template) file
- **Method:** `run grep -n '{{.*}}' "$file"` then `assert_failure` (no args)
- **Success:** When grep finds NO matches (exit 1), assert_failure passes
- **Failure:** When grep finds matches (exit 0), assert_failure fails. On failure, $output contains matched lines with line numbers for diagnostics
- **Known limitation:** Will false-positive on files with legitimate `{{` syntax (JS template literals, GitHub Actions). Currently all managed templates produce shell scripts or config files where `{{` is never legitimate. If future templates generate JS or GHA workflow files, exclude them from this check.

## Non-interactive chezmoi init

All test suites (templates.bats, scripts.bats, platform.bats) depend on `chezmoi init` having been run non-interactively. The init requires CHEZMOI_NAME and CHEZMOI_EMAIL env vars to avoid interactive prompts.

**Required env vars (must be set before any test execution):**
- `CHEZMOI_NAME` — e.g., "Test User"
- `CHEZMOI_EMAIL` — e.g., "test@example.com"

These are set in:
- CI workflow: `env:` block at job level
- Docker: `environment:` in docker-compose.yml
- Local: user must export before running tests

## CI/CD Changes

### .github/workflows/test-dotfiles.yml

- `submodules: recursive` in checkout step (provides bats-libs)
- Job-level `env:` for CHEZMOI_NAME/CHEZMOI_EMAIL (non-interactive init)
- `chezmoi init --source=./home` before template tests (provides data context)
- **Staged test execution** (steps within a single job — GHA default behavior stops on failure):
  1. `bats tests/helpers_test.bats` — validate infrastructure
  2. `bats tests/templates.bats` — fast pre-check gate (no apply needed)
  3. `chezmoi apply` — apply dotfiles
  4. `bats tests/smoke.bats tests/scripts.bats tests/platform.bats tests/idempotent.bats` — post-apply tests

### Docker (docker-compose.yml)

- Volumes mount entire tests/ dir (includes bats-libs after submodule init on host)
- No dedicated test-templates service (YAGNI)

### Makefile

- `make init-submodules` — prerequisite target: `git submodule update --init --recursive`
- All test targets depend on `init-submodules`
- `make test-templates` — template tests only (fast)
- `make test-all` — full suite
- `make lint` — shellcheck on scripts

## Dependencies

- bats-support (git submodule, pinned to tagged release)
- bats-assert (git submodule, pinned to tagged release)
- bats-file (git submodule, pinned to tagged release)

## Out of Scope

- Code coverage (kcov)
- Performance benchmarking
- Mocks/stubs for external commands
- DRY_RUN mode
- Runtime behavior testing of install-packages script
