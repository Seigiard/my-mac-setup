---
title: "Add bounded open-pipe regression for fail-open tests"
short_description: "A nested bashunit regression must hold a non-TTY stdin pipe open and fail within a fixed deadline if any no-payload hts_run_fail_open_guard call again inherits the runner pipe instead of receiving EOF."
type: "follow-up"
category: "testing-ci"
tags: ["bashunit","inherited-descriptors","regression-test","herdr-task-sync"]
date: "2026-08-29"
status: "open"
priority: "medium"
---

## Why this exists

PR #98 fixes the observed Docker-suite hang by redirecting three no-payload fail-open guard calls from /dev/null. Static review confirmed the causal fix, but the committed suite still detects a removed redirect only by hanging until an outer CI timeout; the exact open inherited-pipe condition needs a bounded behavioral owner.

## Scope

1. Add a bounded nested bashunit scenario that keeps a non-TTY stdin write end open while running the affected fail-open paths.
2. Assert process exit and output-pipe EOF before a state-aware deadline for tests 119 and 121.
3. Calibrate the regression by demonstrating that removing an affected /dev/null redirect makes the new scenario fail for the inherited-pipe reason.
4. Keep this test-fixture stdin contract separate from the existing detached-child descriptor probes, which own production descendant descriptors.
5. Verify the focused scenario, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh, and make test-ubuntu.

## Open decisions

Whether one nested invocation can cover both affected tests without materially extending scripts_test.sh wall time, or two narrower invocations provide clearer failure attribution.
