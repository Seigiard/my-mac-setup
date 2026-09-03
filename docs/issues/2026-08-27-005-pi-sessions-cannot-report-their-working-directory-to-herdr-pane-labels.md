---
title: "Pi sessions cannot report their working directory to herdr pane labels"
short_description: "A pi agent pane keeps showing its launch directory on the herdr sidebar, because pi has no worktree concept and no reporter hook that publishes a session directory."
type: "follow-up"
category: "agent-platform"
tags: ["herdr","worktree"]
date: "2026-08-27"
status: "open"
priority: "low"
---

## Why this exists

herdr-worktree-identity sources an agent pane's effective directory from a record the agent writes, since no agent kind changes its process working directory when work moves into a worktree. Claude Code writes that record from its statusline. Pi has neither an equivalent hook nor a worktree concept of its own, so a pi pane always falls back to its process cwd. This is lower priority than the OpenCode gap because pi has no in-session directory move to miss today; it becomes a real gap only once pi gains one.

## Scope

Confirm whether pi has, or plans, an in-session directory change worth reporting. If it does, add a hook that writes the same one-line record the Claude statusline writes: an absolute directory path, at $HERDR_WORKTREE_IDENTITY_STATE_DIR/agent-cwd/<sanitized session id>, written to a temporary file and renamed into place. If it does not, close this as wontfix and record that pi panes are accurate by construction. Out of scope: any change to the herdr-worktree-identity reader.

## Open decisions

None.
