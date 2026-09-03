---
title: "Detached worktree identity worker stalls parallel bashunit"
short_description: "test_scripts_1141 leaves a blocked detached worker holding bashunit output pipes after teardown removes its release file, so make test-ubuntu never completes."
type: "bug"
category: "testing-ci"
tags: ["worktree-identity","bashunit","process-lifecycle"]
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

Updated herdr-worktree-identity detachment to close inherited descriptors above stderr before exec. The existing detached-worker regression test now completes, and the full parallel scripts_test.sh suite passed with 264 tests, 1 expected skip, and 1325 assertions in 1m28s.
