---
title: "Add bounded open-pipe regression for fail-open tests"
short_description: "A nested bashunit regression must hold a non-TTY stdin pipe open and fail within a fixed deadline if any no-payload hts_run_fail_open_guard call again inherits the runner pipe instead of receiving EOF."
type: "follow-up"
category: "testing-ci"
tags: ["bashunit","inherited-descriptors","regression-test","herdr-task-sync"]
date: "2026-08-29"
status: "done"
priority: "medium"
closed: "2026-08-30"
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

## Resolution

Added tests 259/260 in tests/bashunit/scripts_test.sh: each reruns an affected fail-open test (119, 121) under a nested bashunit whose stdin is a non-TTY pipe held open with no payload, and asserts process exit plus output-pipe EOF within an env-overridable budget, with a ps-based descendant scan that names the blocked cat when the inherited-pipe regression is present (status 125). Open decision resolved as two narrower invocations for clear failure attribution; the only extra cost over one invocation is a second runner startup. Calibrated red/green: removing the /dev/null redirect from test 119 or 121 failed the matching scenario with status 125 inside its budget; with redirects intact both pass. Verified: focused runs of 259/260, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh (254 passed, 2 pre-existing skips, 4 pre-existing risky), make test-ubuntu exit 0, make lint. Cross-model review applied one fix (removed the EOF-join grace floor that could accept EOF past the deadline).
