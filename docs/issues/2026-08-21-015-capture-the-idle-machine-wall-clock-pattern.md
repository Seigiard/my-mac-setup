---
title: "Capture the idle-machine wall-clock bound as a documented pattern"
short_description: "Four load-sensitive failures were independently misdiagnosed because idle-machine deadlines conflated hang guards with performance assertions, so the causal-testing pattern needs a durable `docs/solutions` entry."
type: "follow-up"
category: "repository-maintenance"
tags: ["repository-maintenance","follow-up"]
date: "2026-08-21"
status: "open"
priority: "low"
---

## Why this exists

The same defect has now been found four times in this repository, three of them
in a single file, and it is written down nowhere durable. Each instance was
diagnosed from scratch.

| Bound | Where | What it did under load |
|---|---|---|
| 1000 ms envelope | eight-pane coordinator test | Measured a serial tail, not concurrency (`docs/issues/2026-08-20-002`, closed) |
| 75 ms git probe | `HERDR_TASK_SYNC_GIT_BUDGET` | `kill -9` on healthy probes |
| 2 s fail-open | four assertions in `tests/scripts.bats` | Red with no regression behind it |
| 5 s engine watchdog | `HTS_TIMEOUT` default | `kill -9` mid-call; the invocation then committed nothing, and the ordering tests waiting on that commit timed out and looked like a coordinator bug (`docs/issues/2026-08-20-010`) |

One shape: a wall-clock number chosen on an idle machine, correct there, and
falsified the moment real concurrency exists. The failure is expensive to read
because it never looks like what it is — a killed healthy probe reads as a
coordinator ordering defect, and the investigation starts in the wrong place.

Two general rules came out of the fixes, both worth stating once:

- **A hang guard and a performance assertion are different budgets and must not
  share a number.** A guard should be generous and should essentially never
  fire; an assertion should be tight and is the thing that catches regressions.
  Collapsing them means the guard's tolerance silently becomes the assertion's,
  which is how `docs/issues/2026-08-21-014` happened.
- **Where a guard mirrors a production value, track the shipped value rather than
  inventing a test-only one.** The watchdog fix moved the test to production's
  own 30 seconds, so the tests now exercise the watchdog that ships.

A third rule earned separately in the same work, narrower but just as reusable:
a test that hardcodes a shared `/tmp` path is safe only until something runs it
concurrently with itself.

The strongest available fix is not a bigger number at all. It is to assert the
property causally instead of temporally — the R8 repair replaced a wall-clock
bound with a blocking fixture, so the regression now makes the test hang and
fail rather than pass. Where that move is available it removes the whole class.

## Scope

- Write `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md`.
  The evidence is already assembled in issues `2026-08-20-002`, `2026-08-20-010`,
  and `2026-08-21-014`; this is extraction, not fresh analysis.
- It would be the corpus's first entry about test-harness timing rather than
  se-pipeline architecture, so it likely wants its own `component:` value.
- Cross-reference, do not merge with,
  `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md`.
  That document already states the underlying principle — separate liveness from
  budget, calibrate from healthy runs rather than one pathological sample — but
  scoped to external agent subprocesses. Same principle, different domain, and
  the pair is more useful than either alone.

## Open decisions

- Whether the shared-`/tmp`-path lesson belongs in the same document or its own.
  It is a different mechanism (collision, not timing) that happened to surface in
  the same work.
