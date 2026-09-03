---
title: "OpenCode sessions cannot report their working directory to herdr pane labels"
short_description: "An OpenCode agent that moves into a worktree keeps showing its launch directory on the herdr sidebar, because OpenCode exposes no reporter hook equivalent to the Claude Code statusline."
type: "follow-up"
category: "agent-platform"
tags: ["herdr","worktree"]
date: "2026-08-27"
status: "open"
priority: "medium"
---

## Why this exists

herdr-worktree-identity now sources an agent pane's effective directory from a record the agent itself writes, because no agent kind changes its process working directory when its work moves into a worktree. Claude Code can write that record from its statusline command, which receives the session directory as JSON on stdin. OpenCode has no equivalent hook, so an OpenCode pane still falls back to its process cwd and names the directory it was launched in for the rest of the session. The sidebar is then confidently wrong rather than merely uninformative.

## Scope

Find or add an OpenCode extension point that fires on session start and on any directory change, and have it write the same one-line record the Claude statusline writes: an absolute directory path, at $HERDR_WORKTREE_IDENTITY_STATE_DIR/agent-cwd/<sanitized session id>, written to a temporary file and renamed into place. The reader side needs no change. Out of scope: changing how herdr-worktree-identity reads the record, and any change to the Claude Code path.

## Open decisions

None.
