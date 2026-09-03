---
title: "make lint fails on a stale leftover agent worktree"
short_description: "shellcheck globs ./.claude/worktrees/agent-af16a2e90bb22742f/ and reports 38 findings all inside that stale worktree (zero elsewhere), so make lint exits 1 on a clean tree; exclude .claude/worktrees/ from the lint glob or clean up the leftover worktree."
type: "chore"
category: "repository-maintenance"
tags: ["lint","worktree"]
date: "2026-09-03"
status: "open"
priority: "medium"
---

## Why this exists

Describe the problem and its impact.

## Scope

Define the work that resolves this issue.

## Open decisions

None.
