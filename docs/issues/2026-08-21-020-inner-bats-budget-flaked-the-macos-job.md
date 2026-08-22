---
title: "The nested-Bats wall-clock budget flaked the macOS CI job"
short_description: "One 90-second budget covered a nested Bats run whose cost is dominated by parsing 196 unrelated tests, leaving a 1.5x margin that ordinary CI variance exceeded; it is split into a hang guard plus an exit assertion and stays open until three consecutive green test-macos runs."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","herdr","bug"]
date: "2026-08-21"
status: "open"
priority: "high"
---

## Why this exists

`herdr-task-sync bounded Bats invocation exits after detached work`
(`tests/scripts.bats`) failed on the `test-macos` job of CI run
[32454626507](https://github.com/Seigiard/my-mac-setup/actions/runs/32454626507),
on `main` at `9f539b5`. The `test-ubuntu` and `lint` jobs passed. The failure was
load, not a regression.

```
not ok 130 herdr-task-sync bounded Bats invocation exits after detached work
#   `assert_success' failed
# status : 124
# output (2 lines):
#   inner Bats invocation exceeded 90 seconds
#   1..1
```

### The causal chain

1. The test spawns a nested Bats invocation of its own file —
   `bats tests/scripts.bats --filter '^herdr-task-sync descriptor child probe$'` —
   inside a Python heredoc, and capped the whole nested run with one fixed
   wall-clock budget, `HTS_INNER_BATS_TIMEOUT`, default 90 seconds.
2. Most of that nested run is work unrelated to the property under test: Bats
   parses and gathers all 196 tests of the 5105-line file before running the one
   test that survives `--filter`. Measured on a 10-core macOS host,
   `bats --count tests/scripts.bats` costs 1.9 s of CPU out of a 3.9 s nested run
   and a 6.9 s outer test.
3. On the 3-core `macos-latest` runner the same nested run costs about ten times
   more. In the last green macOS run (32453886866) test 130 printed 64.0 s after
   test 129; in the red run that gap was 95.0 s while the nested run is known to
   have hit its 90 s cap. So gap ≈ duration + 5 s, putting the green nested run at
   ≈59 s against a 90 s budget — a 1.5x margin.
4. The red run was ~1.36x slower overall than that green run (suite wall time
   371 s vs 272 s). A 1.36x-slower run against a 1.5x margin exceeds 90 s,
   `subprocess.run(..., timeout=90)` raises `TimeoutExpired`, and the outer
   `assert_success` fails.

### Why this was load and not the regression the test guards

Exit status 124 alone cannot separate the two causes. `subprocess.run` reads to
end-of-file, and a missing EOF is exactly the signature of the regression this
test guards — a detached descendant holding an inherited descriptor open. Both
causes produce the same exit code.

The discriminator is whether the nested run reached its own completion signal
before the expiry, and it is visible in the captured output:

| Cause | Captured stdout |
|---|---|
| Load (what happened) | 2 lines: the driver's message and `1..1` |
| Leaked descriptor | 3 lines: the same two plus `ok 1 herdr-task-sync descriptor child probe` |

The red run printed two lines with no `ok 1`, so the nested test body had not
finished — the expiry landed before completion and the leaked-pipe branch did not
fire.

That table is not inference. It was produced by rehearsal: neutering
`close_inherited_descriptors` (`home/dot_local/bin/executable_herdr-task-sync`)
and running the test yields the three-line form with `ok 1` present, every time.

### Prior handling

`docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md`
named this same test as a co-failure under `--jobs 12`, but attributed the pair to
the 5 s engine watchdog it fixed. That fix did not touch this budget. Its closing
note asked for exactly this: a fresh issue when a new load-sensitive flake appears
in this file.

This is the fifth instance of the pattern
`docs/issues/2026-08-21-015-capture-the-idle-machine-wall-clock-pattern.md`
tracks — a wall-clock number calibrated on an idle machine, correct there, and
falsified the moment real concurrency exists. `HTS_INNER_BATS_TIMEOUT` had already
been recalibrated once, from 12 s to 90 s, with a comment recording that 12 s "was
calibrated on an idle machine and timed out under parallel load".

## Scope

- `tests/scripts.bats` — the outer test, its Python driver, the blocking `herdr`
  stub, and the harness timing-constants block.
- `home/dot_local/bin/executable_herdr-task-sync` is **not** in scope. The
  production script is correct; only the test's bound was wrong. It is edited
  during the rehearsal and reverted.

## Open decisions

- None outstanding. The confirmation criterion below is the remaining work.

## The fix

The single whole-run budget is replaced by two separately named bounds, applying
the rule `2026-08-21-015` states: a hang guard and a performance assertion must
not share a number.

- `HTS_INNER_BATS_PROGRESS_SECONDS` (600 s) is the hang guard. It covers the
  nested run up to the probe writing its pid file, absorbing the whole
  load-elastic parse. It never fires in a healthy run or in the regression.
  Bounded on both ends: far above the ≈59 s observed cost, and far below the
  macOS job's `timeout-minutes: 25` so a genuine hang prints the guard's own
  message instead of the job being killed with none.
- `HTS_INNER_BATS_EXIT_SECONDS` (30 s) is the assertion, and the only bound that
  can fire on a healthy run. It covers Bats teardown and exit alone.

The causal remedy `2026-08-21-015` prefers was unavailable: a held pipe and a
released pipe differ only in elapsed time, with no marker a test could block on.
So the split is the fallback, applied deliberately rather than as an unnoticed
exception.

Three supporting changes came out of implementing it:

- **The driver waits for exit *and* pipe EOF, never exit alone**, and the nested
  run keeps receiving pipes rather than temp files. A worker holding a file
  descriptor blocks nothing, so redirecting to files would have made the test
  pass unconditionally. In practice the leak trips the process wait first (see
  the note under the status table), but both are checked because both are the
  same fault.
- **Both pipes are drained from launch by reader threads.** Leaving them unread
  through the progress phase would deadlock a chatty nested run against a full
  pipe buffer — reachable on the nested-test-failure path, where Bats echoes the
  failed test's captured output.
- **Non-vacuity is asserted, not assumed.** The blocking stub records a durable
  give-up marker when it hits `HTS_BLOCKED_HERDR_CEILING_SECONDS`, and the driver
  refuses to pass when that marker exists. This was found by rehearsal: the first
  implementation checked the presentation coordinator's liveness instead, and the
  coordinator is the stub's *parent* — it outlives the stub's give-up, so the
  check passed on a run that proved nothing.

Each failure mode now exits with its own status and names itself:

| Status | Meaning |
|---|---|
| 124 | never reached its completion signal (hang guard) |
| 125 | completed, then failed to finish — the guarded regression |
| 3 | ended before completing its test |
| 4 | the fixture gave up; nothing was being held |
| 5 | detached worker outlived its release |
| 7 | the nested test failed on its own terms |

126 and 127 are deliberately avoided: the shell reserves them, and bats reports a
misleading `BW01` warning when a `run` command exits with either. The nested run's
own status is carried in the message rather than forwarded as the driver's exit
code, so it cannot coincide with one of these and claim a failure mode that did
not happen.

**A held descriptor stops the whole nested invocation, not just the pipes.** The
first implementation split status 125 into "Bats never exited" and "Bats exited
but its pipes stayed open", on the assumption that a leaked descriptor only
affects the latter. Rehearsal disproved it: Bats' own formatter reads its pipeline
to EOF, so a descendant holding the write end stops the top-level Bats process
from finishing at all — the process wait times out, not the reader join. The split
would have filed the real regression under "Bats is stuck, which is not the
descriptor bug". The two symptoms are one condition; the message names whichever
was observed.

### Measured margins

| Phase | Idle | Under 16 CPU hogs | Bound | Margin |
|---|---|---|---|---|
| Exit (the assertion) | 0.011 s | 0.040 s | 30 s | ~750x |
| Whole run (the old budget) | 6.9 s | 16.0 s | 90 s | 1.5x on CI |

The driver prints the exit-phase duration on every run, passing runs included, and
the test forwards it to bats' console descriptor — so a green CI run carries the
number the bound gets recalibrated against, instead of it being reconstructed from
TAP print-order gaps.

### Rehearsals

Both were run and reverted; neither is committed.

- **Regression.** With `close_inherited_descriptors` neutered in
  `home/dot_local/bin/executable_herdr-task-sync` — the checkout copy the harness
  runs via `HTS_ENGINE`, not the deployed `~/.local/bin` copy — the test fails
  with status 125: `the Bats process never exited within 30 seconds of its test
  completing -- a detached descendant is holding an inherited descriptor open`.
- **Vacuity.** With `HTS_BLOCKED_HERDR_POLLS=1` the test fails with status 4:
  `the blocked herdr stub hit HTS_BLOCKED_HERDR_CEILING_SECONDS and gave up, so
  nothing held a descriptor while the inner Bats exited -- this run proved
  nothing`.

## Confirmation criterion

**This issue stays open until three consecutive green `test-macos` runs of the
post-apply suite.** Every piece of evidence above was gathered on a 10-core host,
which cannot produce the 3-core profile where this reproduces, and a flake that
has fired twice in CI is not shown fixed by a passing local run. Landing the PR
does not close it.

**Reopen trigger.** Any `test-macos` failure of this test at status 125 (the exit
bound) after the criterion is met. That would mean either a genuine
`close_inherited_descriptors` regression or that 30 s is not the margin the
measurements above suggest — the printed exit-phase duration in the same CI log
distinguishes them.
