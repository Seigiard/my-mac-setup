---
title: "bats runs leak orphaned herdr-child watcher daemons"
short_description: "Suite runs leave herdr-child __watcher processes (10ms pollers) behind when their --launcher-pid process dies without reaping them; 12 accumulated orphans measurably slowed all subsequent suite timings machine-wide until killed, so repeated local runs progressively degrade both the machine and any benchmark numbers."
type: "bug"
category: "testing-ci"
tags: ["herdr","process-cleanup","test-isolation","performance"]
date: "2026-08-28"
status: "done"
priority: "medium"
closed: "2026-08-30"
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
  watcher being reaped (the teardown reap loop moved to
  `tests/bashunit/scripts_test.sh:22-41` in the bashunit migration 051d3de and
  still does not catch everything, e.g. kills mid-test or nested runs).
  Candidate escape points in `home/dot_local/bin/executable_herdr-child`: the
  `HERDR_CHILD_TEST_ARM_BARRIER` wait and the `HERDR_CHILD_TEST_WATCHER_RELEASE`
  wait both spin without a `kill -0 "$launcher_pid"` check, unlike the
  takeover/acceptance waits at lines 676 and 688.
- Make the suite reap its own watchers deterministically (or make watchers
  self-terminate when their launcher pid dies — they already poll it every
  10ms, so exiting on a dead launcher is the natural fix at the source).
- Add a regression guard: a suite-end check that no `herdr-child __watcher`
  with a dead launcher survives the run.

## Open decisions

- Fix in the watcher itself (exit when launcher pid vanishes) vs. in test
  teardown (broader reap) vs. both. The watcher-side fix also protects real
  (non-test) herdr usage from the same leak.

## Findings (2026-08-29)

Three escape paths confirmed by deterministic reproduction (red on the
pre-fix revision, green after):

1. `HERDR_CHILD_TEST_ARM_BARRIER` wait: spun at 10ms with no
   `kill -0 "$launcher_pid"` check, so a SIGKILLed harness (which writes no
   `abort.state`) orphaned the watcher forever.
2. `HERDR_CHILD_TEST_WATCHER_RELEASE` wait: the launcher legitimately exits
   before this hold is released, so launcher liveness cannot free it; an
   abandoned hold (harness killed before touching the release file) spun
   forever.
3. Main supervision loop — the shape every live orphan on the machine
   actually had (`ps` showed dead launcher, deleted run dir, growing
   /dev/null write offset): once teardown removes the run dir, the
   `herdr pane get` error path fails to write `$run_dir/pane-get.err`, the
   `pane_not_found` grep finds nothing, and the loop treats every iteration
   as transient — polling forever at `POLL_INTERVAL` (10ms in lifecycle
   tests). This branch also affects real herdr usage when run state is
   removed while herdr is unreachable.

Fix: watchers now exit when their run dir disappears (main loop, release
hold, invalidation loop); the pre-arm barrier fails on a dead launcher; all
test-only barrier holds (arm, release, failure-publish) are bounded by
`HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS` (default 120s). Test teardown
escalates TERM→KILL, the blocking herdr stubs are bounded, and
`tests/run-post-apply.sh` fails the run if any watcher from this checkout
survives with a dead launcher (then reaps it).

## Resolution

Fixed at the source in home/dot_local/bin/executable_herdr-child: watchers now exit when their supervision run dir is externally removed (main loop, release hold, invalidation loop) — this was the escape every observed orphan actually took, since a deleted run dir made the herdr error path look transient forever; the pre-arm test barrier fails on a dead launcher (launcher-lost-before-arm); all test-only barrier holds are bounded by HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS (default 120s). Suite-side: teardown escalates TERM to KILL, all blocking herdr-stub loops are bounded, and tests/run-post-apply.sh fails the run and reaps any watcher from this checkout with a dead launcher AND missing run dir (both criteria required so a concurrent run's legitimately held watcher is not a false positive; pid identity is re-verified before TERM and KILL). Regression coverage: scripts_test 259/260/261 (launcher death, torn-down state, bounded hold — each proven red on the pre-fix revision) and smoke_test 076 (guard reaps only abandoned fakes, controls survive). Verified: full scripts+smoke suites green on host, make lint, make test-ubuntu green in Docker; a pre-fix baseline suite run leaked a watcher while the fixed run left zero.
