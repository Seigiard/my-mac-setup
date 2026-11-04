---
title: Retire the Herdr TUI server
status: accepted
date: 2026-11-04
supersedes: []
---

# ADR-0026: Retire the Herdr TUI server

## Context

This repository started the Herdr TUI server with launchd and installed a set
of plugins around it. The app now owns the user-facing workspace and agent
surfaces, while `hc` and herdr-core own agent communication.

The server, its launchd job, and its plugin lifecycle add machine state that is
not needed by the owner. Keeping those sources also makes a clean apply
recreate software that has already been replaced.

## Considered options

- Keep the server and its plugin lifecycle for compatibility.
- Disable only the launchd job and leave the package and configuration sources.
- Remove the server, its plugin sources, its integrations, and its package
  installation while keeping the standalone consumers that still have callers.

## Decision

Retire the Herdr TUI server and its installed plugin lifecycle from this
repository. The remaining plugin decisions are:

| Former component | Decision and replacement |
|---|---|
| `seigi.command-palette` | Dropped. The app mods and direct shell commands cover the supported actions. |
| `seigi.focus-notify` / `herdr-focus-notify` | Dropped. No replacement is needed. |
| `herdr-wakeup` | Dropped. The replacement is tracked by #632. |
| `herdr-agent-metrics` | Dropped. The app surfaces the required agent limits through #595. |
| `herdr-theme-picker` | Dropped. Terminal themes remain managed by the terminal configs. |
| `keepawake.caffeinate` | Dropped. The replacement is tracked by #632. |
| `herdr-auto-update` | Dropped with the TUI plugin lifecycle. Updates now use reviewed repository changes. |
| `jmarbutt.spaces-pr-status` | Dropped. Pull-request status is provided by #593. |
| `seigi.pane-labels` | Dropped. Sidebar and tab behavior are provided by #594 and #602. The `hc-run` alias library remains a pinned external. |
| `seigi.worktree-setup` | Replaced by the standalone pinned external from #616. Its policy remains managed at `~/.config/herdr-worktree-setup/config.toml`. |

The Herdr app provides the workspace, sidebar, pull-request, tab-name, and
agent-limit behavior through #594, #593, #602, and #595. The standalone
worktree setup package from #616 remains. The communication substrate from
#617 remains. Wakeup has a separate replacement in #632.

## Consequences

Applying this repository no longer installs the `herdr` Homebrew package,
launchd job, TUI plugin configs, or integration hooks. The user must remove
the old machine state once, using the commands listed in the change report.

`hc-run` keeps its alias-library dependency through a pinned chezmoi external.
Claude Code worktree setup reads its policy from the standalone package path.
Historical research and plan records remain unchanged.

## Status notes

- The week-long process gate from #618 is waived by the owner.
- Wakeup replacement work belongs to #632.
- Merge to the default branch remains the owner's decision.
