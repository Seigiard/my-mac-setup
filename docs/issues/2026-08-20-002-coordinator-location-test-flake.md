---
title: Coordinator eight-pane location test flakes at the 1000ms envelope boundary
type: bug
date: 2026-08-20
status: open
---

## Why this exists

`bats tests/scripts.bats --filter 'coordinator resolves eight pane locations'`
(tests/scripts.bats, test "herdr-task-sync coordinator resolves eight pane
locations concurrently within one event envelope") intermittently fails on this
machine: the measured envelope lands at ~1024ms against the 1000ms assertion
budget.

The flake pre-dates the git_ref label work: during the 2026-08-20 cross-review
it reproduced both at branch HEAD and at base commit `93dd91d` (verified by
extracting the base tree with `git archive` and running the identical filter).
It passed in the same session's full-suite runs, so it is load-sensitive, not
deterministic.

## Scope

- Decide: widen the envelope budget, reduce fixture work inside the envelope,
  or measure with a load-tolerant bound (e.g. median of retries).
- Keep the test's intent: eight panes must resolve concurrently, not serially
  (a serial run would take ~8x the per-pane budget, far above any sane bound).

## Open decisions

- Whether the 75ms per-pane git budget assertion elsewhere shares the same
  load sensitivity.
