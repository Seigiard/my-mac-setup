---
title: Coordinator eight-pane location test flakes at the 1000ms envelope boundary
type: bug
date: 2026-08-20
status: done
closed: 2026-08-20
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

## Resolution

Removed the `elapsed < 1000` wall-clock assertion and its timing plumbing from
the test; kept the barrier, the deadline (raised from 1s to 30s as a pure hang
guard), and every state assertion.

The budget measured the wrong thing. The window from barrier release to
`completed_generation` spans two phases: the eight concurrent location probes,
and the serial presentation pass that follows them
(`home/dot_local/bin/executable_herdr-task-sync:1427-1490`). Instrumented over
six idle runs, the probe phase was a stable 124-131ms while the serial tail was
440-468ms -- 78% of the measured window. The tail is process-spawn bound, so it
tracks runner speed and machine load, which is why 11 of 12 CI failures were on
macOS runners and only 1 on ubuntu. Reproduced deterministically: under CPU
saturation the test failed 5/5 while the probe phase stayed at 215-321ms.

Concurrency never depended on the timer. `HERDR_TASK_SYNC_TEST_LOCATION_BARRIER_COUNT=8`
makes every probe publish a marker and spin until all eight exist
(`executable_herdr-task-sync:1399-1413`), so serial probes deadlock on the first
one and `hts_wait_for_file` fails the test before the timer would even start.
Verified by mutation: serializing the probe spawn makes the test fail at
`tests/scripts.bats:3325`, with the wall-clock assertion already gone.

The open decision above is answered: no other wall-clock assertion exists. The
`HERDR_TASK_SYNC_GIT_BUDGET=0.075` uses at tests/scripts.bats:3181 and :3259 are
script inputs that produce a deterministic watchdog kill; those tests assert on
resulting state, not on elapsed time. This was the only wall-clock assertion in
the suite.

CI impact: this test accounted for 11 of the 18 red runs in the last 29. The
other 12 came from `Pi terminal theme uses only terminal palette colors`, closed
separately by `8cb70d8`.

The `command -v python3 || skip` guard went away with the last python3 use, so
the test no longer silently skips on a python3-less machine.
