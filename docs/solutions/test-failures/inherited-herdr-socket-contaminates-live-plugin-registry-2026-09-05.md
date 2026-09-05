---
title: Inherited Herdr socket contaminates the live plugin registry
date: 2026-09-05
category: test-failures
module: herdr-command-palette
problem_type: test_failure
component: testing_framework
severity: high
symptoms:
  - "A real Herdr CLI test registers a local plugin from an ephemeral worktree in the live server"
  - "After the worktree is deleted, Herdr reports manifest unavailable and exposes no plugin actions"
  - "Cmd+Shift+P reports custom command failed and plugin action not found"
root_cause: test_isolation
resolution_type: test_fix
related_components:
  - "tooling"
  - "development_workflow"
tags:
  - herdr
  - command-palette
  - plugin-registry
  - test-isolation
  - socket-inheritance
  - ephemeral-worktree
  - bashunit
---

# Inherited Herdr socket contaminates the live plugin registry

## Problem

`tests/bashunit/palette_test.sh` changed `HOME` before running the real Herdr CLI, but a test launched inside Herdr still inherited `HERDR_SOCKET_PATH`. The explicit socket sent `herdr plugin link` to the live server, which persisted the command-palette path from the current test worktree. Herdr also supports other session and config-root overrides, so changing `HOME` alone is not a complete isolation boundary.

When that worktree was removed, the registered manifest disappeared. Herdr kept the cached plugin entry for inspection but excluded its actions from resolution, so `seigi.command-palette.open` failed at keypress time.

## Symptoms

- `herdr plugin list --json` shows `seigi.command-palette` rooted in a deleted worktree with a `manifest unavailable` warning.
- `herdr plugin action list --plugin seigi.command-palette` returns no actions.
- `Cmd+Shift+P` shows `custom command failed` and `plugin action not found`.

## What Didn't Work

Changing only `HOME` does not isolate a socket-aware Herdr command:

```bash
env HOME="$home" herdr plugin link "$PALETTE_DIR" --enabled
```

`HERDR_SOCKET_PATH` takes precedence and routes the mutation to the running server. `herdr server reload-config` also cannot repair this state because it reloads `config.toml`, not plugin registration.

## Solution

Start the real CLI check with a clean environment and verify the persistent side effect in the disposable home:

```bash
run env -i HOME="$home" PATH="$PATH" \
  herdr plugin link "$PALETTE_DIR" --enabled
assert_success
local link_json="$output"

local registry="$home/.config/herdr/plugins.json"
assert_file_exists "$registry"
```

The test parses `plugins.json` and requires `seigi.command-palette` to point at `$PALETTE_DIR`. It saves the first `run` output because the repository test DSL overwrites `$output` on every subsequent `run`.

Repair an already contaminated live registry by replacing the same plugin ID with the stable managed path:

```bash
herdr plugin link ~/.config/herdr/plugins/command-palette --enabled
```

Relinking validates the new manifest before replacing the existing registration. An unlink-first window is unnecessary.

## Why This Works

The clean environment removes inherited socket, named-session, and config-root overrides. Herdr resolves its state from the disposable `HOME` and writes that home's `.config/herdr/plugins.json`. The test still exercises Herdr's real manifest parser and registry persistence, but it cannot reach the user's running server.

The regression assertion observes the filesystem boundary rather than trusting successful CLI output. Before the fix, the command succeeded while the disposable registry remained empty and the live registry changed. After the fix, the focused test and all 62 command-palette tests passed, covering 228 assertions.

## Prevention

- Treat endpoint and config-root variables as part of test isolation. Changing `HOME` alone is insufficient when a CLI accepts explicit environment overrides.
- For a real Herdr CLI test that needs no ambient state, use `env -i` and restore only required inputs such as `HOME` and `PATH`.
- Assert the mutation in the disposable registry so a command routed to the wrong server cannot produce a false green.

## Related Issues

- [Semantic regression tests over source shape](../design-patterns/semantic-regression-tests-over-source-shape.md)
- [Herdr git-status playground plan](../../plans/2026-08-25-001-feat-herdr-git-status-playground-plan.md)
- [Task-sync tests measure only an unverified Herdr protocol fake](../../issues/2026-09-02-012-herdr-task-sync-tests-measure-only-an-unverified-herdr-protocol-fake.md)
- [Palette dynamic plugin action source](../../issues/2026-08-18-008-palette-dynamic-plugin-action-source.md)
