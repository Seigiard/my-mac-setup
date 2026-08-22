---
title: "herdr-task-sync socket namespace test lets location metadata advance"
short_description: "The macOS post-apply suite failed because the socket-namespace collision test expected an untouched location high-water, but a presentation pass had advanced location_metadata_high_water to 1787380724887106."
type: "bug"
category: "herdr"
tags: ["herdr","ci-flake"]
date: "2026-08-22"
status: "open"
priority: "medium"
external-id: "https://github.com/Seigiard/my-mac-setup/actions/runs/32557342258/job/96993615579"
---

## Why this exists

The macOS `test-macos` job failed in run 32557342258, job 96993615579, while running `bats --jobs 8 --no-parallelize-across-files tests/smoke.bats tests/scripts.bats tests/palette.bats tests/platform.bats tests/idempotent.bats`.

The failed test was `herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions` in `tests/scripts.bats:1682`. The failure was at `tests/scripts.bats:1703`, where the test asserts `location_metadata_high_water` is still `0` for `namespace_one/reconcile.state`. CI observed `1787380724887106` instead.

Debug evidence so far:

- The exact failure block from CI says expected `0`, actual `1787380724887106`.
- Local single-test reproduction with `bats tests/scripts.bats --filter '^herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions$'` passed once. This makes the failure load-sensitive or order-sensitive rather than deterministic in isolation.
- Repository issue search found no active issue for `location_metadata_high_water`, `reconcile.state`, or this specific assertion.
- Related closed issue: `docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md`. It tracked the same test name, but closed a different root cause: a 5 s engine watchdog that killed stub engines under contention. This new failure has a different signature: the task commit succeeded, and the location high-water advanced.

Leading hypothesis, not confirmed: the test assumes that successful task naming does not let the presentation/location path complete before the assertion. That assumption is fragile. `commit_task_result` reads and preserves `location_metadata_high_water` while committing task metadata (`home/dot_local/bin/executable_herdr-task-sync:1997-2016`), then `run_worker` starts a presentation coordinator after a successful presentation-required commit (`home/dot_local/bin/executable_herdr-task-sync:2124-2126`). A completed presentation pass can raise `location_metadata_high_water` to the pass generation in `complete_presentation_generation` (`home/dot_local/bin/executable_herdr-task-sync:1160-1169`). The observed value is in the `now_seq` range, which matches a presentation/location generation rather than the initial namespace value.

The root cause is not confirmed because the CI log did not dump `namespace_one/reconcile.state`, `namespace_two/reconcile.state`, the socket fixture state, or `herdr.log` at failure time.

## Scope

- Confirm whether the failing `location_metadata_high_water` was written by `complete_presentation_generation` after a presentation pass, or by another writer.
- Add a failure-path dump for this test that prints both namespace `reconcile.state` files, the socket fixture state, and `herdr.log` when the assertion fails.
- Decide the intended contract: either this namespace-isolation test should disable/wait for presentation before asserting task-only state, or the engine should avoid advancing location metadata when the fixture has no pane/location work.
- Add or adjust the regression test in `tests/scripts.bats`, because existing coverage already owns the behavior.
- Re-run a contention profile that resembles CI, for example the macOS post-apply command at `--jobs 8`, after adding the diagnostic dump or fix.

## Open decisions

- Whether the assertion at `tests/scripts.bats:1703` is still a valid contract after presentation/location metadata was added.
- Whether the fix belongs in the test harness, by disabling or waiting for presentation in this task-only namespace test, or in `home/dot_local/bin/executable_herdr-task-sync`, by preventing an empty/no-location presentation pass from advancing location metadata.
