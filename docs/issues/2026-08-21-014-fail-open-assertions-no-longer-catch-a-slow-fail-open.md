---
title: "The fail-open assertions widened to 20s and no longer catch a slow fail-open"
short_description: "Three assertions now allow 20 seconds to tolerate scheduler contention, so regressions that delay normally sub-second fail-open paths by 3–18 seconds remain green."
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-21"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md"
closed: "2026-08-23"
---

## Why this exists

Three tests in `tests/scripts.bats` assert that a worker "fails open promptly
rather than hanging" by bounding elapsed wall time. The bound was 2 seconds and
is now `HTS_FAIL_OPEN_MAX_SECONDS`, 20 seconds:

```sh
[[ $((end - start)) -le $HTS_FAIL_OPEN_MAX_SECONDS ]]
```

It was raised because 2 seconds was calibrated on an idle machine and went red
under `--jobs` contention with no regression behind it. That reason still holds.
The cost is that these assertions no longer discriminate over most of their
useful range: the paths they guard fail open in well under a second, so a
regression that made one of them block for three to eighteen seconds now passes.
They still catch a true hang, which is the smaller half of what they were for.

Four independent reviewers reached this from different directions, which is why
it is filed rather than left as a comment: two rated it a testing gap, and an
independent cross-model adversarial pass rated it P1 with the observation that
load tolerance had replaced the behavioral deadline rather than sitting beside
it.

A fourth site had the same shape and is already fixed, which is what makes this
issue's remaining risk concrete rather than theoretical. The R8 test
("returns before the naming engine finishes") bounded the entry point against
the same 20-second ceiling while its stub slept a fixed 4 seconds -- so a
synchronous wait on the model, the exact regression R8 exists to catch, passed
it. That one was repaired by dropping the clock entirely: the engine stub now
blocks on a release marker, so a regression makes the test hang and fail instead
of passing. The same move is not directly available for the three remaining
sites, because for them promptness genuinely *is* the property under test.

## Scope

The honest fix separates the two budgets these assertions currently conflate:

- A **behavioral deadline** — what the fail-open path must beat — kept tight.
- A **hang guard** — what a contended scheduler must not trip — kept generous.

Ways to get there, roughly in order of preference:

1. Make the assertion structural where a signal exists, as R8's fix did. If the
   fail-open path writes a marker or state record, assert ordering against that
   instead of the clock.
2. Measure the real distribution first. Run these three tests several hundred
   times under `docker run --cpus 4` with `--jobs 8`, record the elapsed
   distribution, and set the deadline above the observed maximum rather than by
   eye. Whatever number that produces is defensible in a way that both 2 and 20
   are not.
3. Subtract the contention. Compare against a same-test baseline captured in the
   same run, so the bound measures the fail-open path rather than the machine.

Do **not** simply lower the constant back toward 2 seconds. That reintroduces the
exact flake this work removed, and a flaky assertion protects nothing because it
gets muted.

## Decisions resolved

Promptness is still part of the test contract. The selected fix keeps the
generous hang guard but adds a scaled same-run baseline plus a tight behavioral
deadline, because these fail-open paths should not silently take several seconds
before returning on an idle runner.

## Resolution

Added a two-budget fail-open guard in tests/helpers/herdr_task_sync.bash, updated the three promptness assertions in tests/scripts.bats to use it, and added a regression test proving a late success fails before the hang guard. The guard scales its same-run baseline so full-suite scheduler contention does not fail a healthy path.
