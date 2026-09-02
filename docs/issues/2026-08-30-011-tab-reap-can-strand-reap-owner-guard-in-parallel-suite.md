---
title: "tab reap can strand reap-owner guard in parallel suite"
short_description: "The reap-owner guard now exits when its run directory disappears, closing the release-file deletion race with a bounded regression and a passing full Ubuntu suite."
type: "bug"
category: "testing-ci"
tags: ["herdr-child","flaky-test","process-cleanup","parallel-tests"]
date: "2026-08-30"
status: "done"
priority: "high"
closed: "2026-09-01"
---

## Why this exists

Observed on 2026-08-30 during the final optimization verification. make test-ubuntu exceeded a 20-minute harness limit and was terminated with exit 130 after hundreds of green tests. The surviving Docker container had scripts_test.sh blocked for more than 19 minutes in 'herdr-child reap --pane wT:p9 child-life'; its only child was the reap-owner Python guard. The fixture had child-tab=wT:tA and require-reap-invalidation, identifying test 092. The generation run directory was already gone while the guard still waited for its release file. Both test 092 and test 045 passed five focused Ubuntu repeats, so the failure requires the full parallel contention profile. This matches the deadline/reap race previously fixed only for test 045 in issue 2026-08-29-004; test 092 still launches with --supervision-timeout 5000.

A current static audit confirms that the trigger exposes a broader guard race.
`stop_reap_owner_guard` publishes the release file and then waits without a
bound, while terminal watcher cleanup can remove the run directory before the
guard observes that file. The 5-second test deadline makes the interleaving
more likely, but tab mode is not the root cause.

## Scope

Reproduce test 092 under the full -j 8 scripts_test.sh contention profile. Make
the production guard terminate when its run directory disappears or otherwise
bound `stop_reap_owner_guard`, and give test 092 the same out-of-reach
supervision deadline as test 045 if the deadline remains unrelated to its
contract. Add a bounded red/green regression that fails instead of hanging.
Verify the focused scenario, complete scripts_test.sh, and make test-ubuntu.

## Open decisions

How the guard should distinguish an intentionally released run directory from
unexpected state loss; a test-only timeout must not mask the production
orphan-guard path.

## Resolution

Made run-directory disappearance terminal for the reap-owner guard, added deterministic normal-release and deletion-race coverage, and verified make lint plus make test-ubuntu.
