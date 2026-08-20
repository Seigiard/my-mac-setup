---
title: Two herdr-task-sync ordering tests flake under full-suite load
type: bug
date: 2026-08-20
status: done
closed: 2026-08-20
---

## Why this exists

Two tests in `tests/scripts.bats` failed once during a full `bats tests/scripts.bats`
run and passed on every subsequent attempt:

- `herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions`
  (tests/scripts.bats:2268) -- closed unreproduced, see Resolution
- `herdr-task-sync orders adapter calls by inbox commit rather than invocation start`
  (tests/scripts.bats:2365) -- **fixed, see Progress below**

Observed on macOS (Darwin 25.5.0), `main` at `601d749`.

Reproduction attempts:

| Command | Result |
|---|---|
| `bats tests/scripts.bats` (first run) | both fail |
| `bats tests/scripts.bats --filter 'exact socket namespaces survive legacy\|orders adapter calls by inbox commit'`, three consecutive runs | both pass every time |
| `bats tests/scripts.bats` (two later full runs) | both pass |
| both tests, 6 consecutive runs each under CPU saturation (10 busy loops on a 10-core machine) | both pass every time |

Both tests are about ordering and locking rather than pure formatting, which fits
a load-sensitive flake: the full suite forks many concurrent fixture processes,
and these two assert an observable ordering between them.

This is a separate test pair from
`docs/issues/2026-08-20-002-coordinator-location-test-flake.md`, which covered the
eight-pane coordinator location test at the 1000 ms envelope boundary and is now
closed. That one turned out to be a wall-clock assertion measuring the serial
presentation tail, not a concurrency defect -- so the "shared root cause" guess
below did not hold for it.

## CI evidence (2026-08-20)

Neither test has ever failed in CI. Checked all 29 most recent `Test Dotfiles`
runs (18 red) with `gh run view <id> --log-failed`: zero occurrences of either
test name. The 18 red runs decompose into
`Pi terminal theme uses only terminal palette colors` (12 runs, closed by
`8cb70d8`), the eight-pane coordinator envelope test (11 runs, closed by
docs/issues/2026-08-20-002-coordinator-location-test-flake.md), and one
`herdr pane-label plugin deploys the approved Herdr 0.8 lifecycle inputs`
failure on a feature branch that did not survive the merge.

So this pair costs nothing in CI today. It is a local-only concern.

## Progress: the inbox-commit ordering test is fixed

Its timing assumption was visible by inspection and is gone.

The test blocks its first engine invocation on a fifo, because opening a fifo for
reading blocks until a writer opens the other end. The release was
`{ sleep 1; printf 'delayed stdin' > "$fifo"; } &` -- a fixed 1 s window inside
which the second invocation had to finish committing. Under full-suite load it may
not, and then the first invocation's engine starts while the second is still
mid-commit, which inverts the very ordering the test asserts.

Replaced with an explicit happens-before: the writer now waits on a release file,
and the test creates that file only after the second invocation has committed and
its control record has gone quiescent. Same contract, no timer.

Verified the test is not vacuous after the change -- instrumented, it shows
`slug=invoked-second-committed-first` immediately before the release and
`slug=invoked-first-committed-second` with a strictly greater committed generation
after it. Passes 3/3 idle and 6/6 under CPU saturation.

## The socket-namespace test: investigated, no mechanism found

No timing assumption was found in it by inspection:

- The test body contains no `sleep` and no timer.
- Its waits are `hts_wait_for_task_slug` and `hts_wait_for_quiescence`
  (tests/scripts.bats:1704 and :1745), both bounded at 1000 iterations x 0.01 s
  = 10 s. That is generous.
- The only fixed bound in the path is the harness engine timeout,
  `HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}"` (tests/scripts.bats:1223), which
  bounds each stub engine call at `executable_herdr-task-sync:1906` and `:1921`.
  A stub call exceeding 5 s under load would be killed, the slug would never be
  written, and `hts_wait_for_task_slug` would then fail at its own 10 s bound.
  That is a hypothesis, not an observation -- nothing has been measured against it.

Six consecutive runs under CPU saturation did not reproduce it, so plain CPU
pressure is not the trigger; the full suite's process and file-descriptor
contention is a different profile.

## Scope

- Capture the failure properly the next time a full-suite run goes red on this
  test. Without output the cause stays guesswork. Worth capturing: the bats
  failure block, whether the engine stub was killed, and the contents of the
  namespace `reconcile.state` and the pane `control.state`.
- Cheap way to test the engine-timeout hypothesis deliberately: run the test with
  `HTS_TIMEOUT=1` and see whether the failure mode matches what a full-suite run
  produces.
- Reproduce with the real trigger if it is worth the time: run the full suite in a
  loop rather than adding synthetic CPU load, since CPU load alone does not do it.

## Resolution

Closed with one test fixed and one closed unreproduced.

**`orders adapter calls by inbox commit rather than invocation start` -- fixed.**
Its fixed `sleep 1` fifo release became an explicit happens-before gated on the
second invocation having committed and gone quiescent. Same contract, no timer.
Confirmed not vacuous by instrumentation. Passes 3/3 idle and 6/6 under CPU
saturation. Full suite after the change: 194 pass, 3 skip, 0 failures.

**`exact socket namespaces survive legacy sanitized-name collisions` -- closed
without a found cause.** This is a deliberate call, not a claim that it was fixed.
Nothing in it was changed. What is on record: it has never failed in CI across 29
runs, it did not reproduce in six runs under CPU saturation, and inspection found
no timing assumption -- no sleep, wait helpers bounded at 10 s, and the only fixed
bound in its path is the 5 s harness engine timeout. One uncaptured local failure
is the entire evidence base, which is too thin to fix against without guessing.

**Reopen trigger.** File a new issue, or reopen this one, if the test fails again.
Capture the bats failure block, whether the engine stub was killed, and the
namespace `reconcile.state` plus the pane `control.state` at the time. The
Scope section above holds the probe worth running first
(`HTS_TIMEOUT=1`) against the engine-timeout hypothesis.
