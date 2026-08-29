---
title: "bats runs leak orphaned herdr-child watcher daemons"
short_description: "Suite runs leave herdr-child __watcher processes (10ms pollers) behind when their --launcher-pid process dies without reaping them; 12 accumulated orphans measurably slowed all subsequent suite timings machine-wide until killed, so repeated local runs progressively degrade both the machine and any benchmark numbers."
type: "bug"
category: "testing-ci"
tags: ["herdr","process-cleanup","test-isolation","performance"]
date: "2026-08-28"
status: "open"
priority: "medium"
---

## Why this exists

During the 2026-08-28 test-suite timing work, two concurrent sessions found the
machine progressively slowing across repeated suite runs. Diagnosis: 12
orphaned `herdr-child __watcher` daemons (each polling at 10ms) plus 2 orphaned
stub prompt processes had accumulated from bats runs — the watchers outlive
their `--launcher-pid` process when it dies without reaping them, despite the
teardown reap loop in `tests/scripts.bats`. The accumulation inflated
full-suite wall time by roughly 7% within an hour (baseline-tree control runs:
full 155s→165s, host 141s→161s) and destabilized benchmark comparisons.

Detection: `pgrep -f "herdr-child __watcher"`. Cleanup that restored the
floor: kill each watcher whose `--launcher-pid` process is dead (see
`ps -o args= -p <pid>` for the launcher pid).

## Scope

- Find the escape path: which test paths let a launcher die without its
  watcher being reaped (teardown reap loop exists at `tests/scripts.bats:6-36`
  but does not catch everything, e.g. kills mid-test or nested-bats runs).
- Make the suite reap its own watchers deterministically (or make watchers
  self-terminate when their launcher pid dies — they already poll it every
  10ms, so exiting on a dead launcher is the natural fix at the source).
- Add a regression guard: a suite-end check that no `herdr-child __watcher`
  with a dead launcher survives the run.

## Open decisions

- Fix in the watcher itself (exit when launcher pid vanishes) vs. in test
  teardown (broader reap) vs. both. The watcher-side fix also protects real
  (non-test) herdr usage from the same leak.
