---
title: "Pre-exec descriptor closure can suppress Linux identity worker"
short_description: "Closing every /dev/fd entry in the launcher subshell can close Bash internal state before exec under Linux setsid, so the detached worker returns control but never reaches its pane-get readiness barrier."
type: "bug"
category: "testing-ci"
tags: ["worktree-identity","linux","process-lifecycle"]
date: "2026-09-03"
status: "done"
priority: "high"
closed: "2026-09-03"
---

## Why this exists

Describe the problem and its impact.

## Scope

Define the work that resolves this issue.

## Open decisions

None.

## Resolution

Moved inherited-descriptor closure from the launcher subshell into validated worker mode, matching executable_herdr-pane-labels. The Linux Docker reproduction passed both filtered tests with 4 assertions in 1.31s, and make lint passed.
