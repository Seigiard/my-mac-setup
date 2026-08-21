---
status: done
---

# Chezmoi Test Isolation: Prevent Config Overwrite

## Problem

`chezmoi init` overwrites `~/.config/chezmoi/chezmoi.yaml` with test data when run from worktrees or local test sessions. This corrupts the host machine's real config (name, email, sourceDir).

## Root Cause

Only `chezmoi init` writes the config file. All other commands (`apply`, `diff`, `verify`, `data`, `execute-template`) are read-only and safe with `--source`.

## Solution

Isolate `chezmoi init` calls using `--config` and `--config-path` flags pointing to `/tmp/chezmoi-test.yaml`.

### Change 1: `tests/helpers/common.bash`

Add `chezmoi_test_init()` function:
- Runs `chezmoi init --config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml --source=<source>`
- Accepts same arguments as `chezmoi init`
- Used by any test that needs to run `chezmoi init` locally

### Change 2: `Makefile` — `test-templates` target

Update the `chezmoi init` call to use `--config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml`.

Note: Docker targets (`test-full`, `test-quick`) run inside containers — already isolated, no changes needed.

### Change 3: `CLAUDE.md` — worktree rule

Add rule: when running `chezmoi init` in a worktree, always use `--config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml`.

### What stays unchanged

- `make test-local` (`chezmoi diff --source=./home`) — read-only, safe
- `chezmoi apply/verify/diff` in bats tests — read-only, use `--source`
- Docker test targets — already containerized
