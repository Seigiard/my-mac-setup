---
title: "herdr-child reap/close race test flakes under CPU load"
short_description: "tests/scripts.bats test 'herdr-child reap invalidates before close while spontaneous loss wakes the parent' (added in #83) failed 3 of ~16 docker runs during loaded 2026-08-29 benchmark reps yet 0 of 10 in calm reruns, so the race window needs a load-tolerant margin rather than a timing assumption."
type: "bug"
category: "testing-ci"
tags: ["flaky-test","herdr"]
date: "2026-08-29"
status: "in-progress"
priority: "medium"
---

## Why this exists

During the 2026-08-29 test-suite benchmark reps, the docker-leg test `herdr-child reap invalidates before close while spontaneous loss wakes the parent` (tests/scripts.bats, introduced by #83 "supervise detached child agents") failed 3 times in ~16 container runs. All runs happened while a runaway host process pinned one core. Independent evidence from a concurrent session: 0/10 failures in a quiet container on both the bats and bashunit runners, plus exactly one failure in a contended run. That is a clean load-sensitivity signature — the scenario's race window (reap must invalidate before close) assumes a scheduling latency that contention breaks. It is runner-independent and distinct from the `hts_teardown` state-dir race.

Each flake poisons a whole measurement or CI run: the suite reports 1 failure and the run must be discarded or retried.

## Scope

- Reproduce under artificial load (e.g., a busy loop pinning cores while looping the single test).
- Widen the scenario's detection margin so a loaded scheduler cannot reorder reap and close, without weakening what it proves (reap-before-close invalidation and parent wakeup on spontaneous loss).
- Confirm 0 failures over a loaded 20-run loop after the fix.

## Open decisions

None.
