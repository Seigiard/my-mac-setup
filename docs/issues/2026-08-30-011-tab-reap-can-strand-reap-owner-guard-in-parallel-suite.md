---
title: "tab reap can strand reap-owner guard in parallel suite"
short_description: "make test-ubuntu can hang in herdr-child test 092 when its 5-second supervision deadline removes the run directory during tab reap, leaving the reap-owner guard waiting on a release path that no longer exists."
type: "bug"
category: "testing-ci"
tags: ["herdr-child","flaky-test","process-cleanup","parallel-tests"]
date: "2026-08-30"
status: "open"
priority: "high"
---

## Why this exists

Observed on 2026-08-30 during the final optimization verification. make test-ubuntu exceeded a 20-minute harness limit and was terminated with exit 130 after hundreds of green tests. The surviving Docker container had scripts_test.sh blocked for more than 19 minutes in 'herdr-child reap --pane wT:p9 child-life'; its only child was the reap-owner Python guard. The fixture had child-tab=wT:tA and require-reap-invalidation, identifying test 092. The generation run directory was already gone while the guard still waited for its release file. Both test 092 and test 045 passed five focused Ubuntu repeats, so the failure requires the full parallel contention profile. This matches the deadline/reap race previously fixed only for test 045 in issue 2026-08-29-004; test 092 still launches with --supervision-timeout 5000.

## Scope

Reproduce test 092 under the full -j 8 scripts_test.sh contention profile. Determine whether the production guard must terminate when its run directory disappears, whether stop_reap_owner_guard can lose the guard PID/release path, or whether test 092 only needs the same out-of-reach supervision deadline as test 045. Add a bounded red/green regression that fails instead of hanging. Verify the focused scenario, complete scripts_test.sh, and make test-ubuntu.

## Open decisions

Whether the correct owner is production reap cleanup, the test 092 deadline, or both; a test-only timeout must not mask a production orphan-guard path.
