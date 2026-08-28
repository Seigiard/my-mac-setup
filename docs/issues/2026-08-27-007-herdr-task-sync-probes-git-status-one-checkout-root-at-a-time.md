---
title: "herdr-task-sync probes git status one checkout root at a time"
short_description: "Each distinct checkout root spends its own status budget in sequence, so a developer with several open worktrees adds most of a second to every five-second sweep."
type: "follow-up"
category: "herdr"
tags: ["performance"]
date: "2026-08-27"
status: "open"
priority: "medium"
---

## Why this exists

The identity probe already runs per pane in parallel, so N panes cost about one budget. build_root_statuses does not follow that pattern: it calls resolve_pane_git_status once per distinct root in a plain loop, so N roots cost N times the 0.3 second status budget in the worst case. Several open worktrees of one project is the exact situation this feature was built for, which makes it the situation most likely to feel the delay. Both peers of a cross-model review raised this independently. Neither could show it preserves behaviour, which is why it was not folded into the original change: forking per root alters resource contention and the timeout semantics that the fresh/stale/absent outcomes depend on.

## Scope

Measure first, with several seeded roots and a raised status budget, so there is a number to beat and a number to verify against. Then fork resolve_pane_git_status per root into a background subshell writing to its own result file, collect the pids, wait, and assemble the table, mirroring the parallel identity-probe loop in the same file. The outcome grammar and every published token must be byte-identical to the serial version. Out of scope: changing the budget values, the outcome names, or the identity probe.

## Open decisions

None.
