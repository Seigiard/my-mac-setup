---
title: Two herdr-task-sync ordering tests flake under full-suite load
type: bug
date: 2026-08-20
status: done
closed: 2026-08-21
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

## Reopened 2026-08-21: the socket-namespace test reproduced under within-file parallelism

`herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions`
-- the half of this pair closed **unreproduced, with nothing changed** -- failed in
CI on 2026-08-21. That closure rested on the test never being reproducible; it now
has been, so this issue is open again.

**Where.** CI run `32435170556`, job `test-macos` (macos-latest, 3 cores), running
the post-apply suite as `bats --jobs 12 --no-parallelize-across-files`. It failed
in the first of three `--jobs 12` repetitions and did not fail in any of the three
`--jobs 8` repetitions in the same job, nor in that job's sequential control.

**Why this profile and not CPU saturation.** This issue already recorded that ten
busy loops on a ten-core machine did not reproduce it, because "the full suite's
process and file-descriptor contention is a different profile". Within-file
parallelism is that profile: 12 concurrent bats tests on 3 cores, each forking
fixture processes. Deliberate CPU starvation does not reproduce it; concurrent
forking does.

**Capture protocol.** The run's other failures in the same repetition were
`herdr-task-sync bounded Bats invocation exits after detached work` and
`herdr-task-sync returns before the naming engine finishes (R8)`. The engine stub
was not reported killed for this test (no `Killed: 9` line accompanied it, unlike
the eight-pane coordinator failures seen earlier in the same investigation). The
namespace `reconcile.state` and pane `control.state` were not captured -- the CI
harness printed 20 lines of context per failure and neither state file is dumped
on failure. **Capturing them needs a teardown hook that dumps both on a failed
test; without it a CI recurrence cannot supply what this issue asks for.**

**Not a blocker for the parallel suite.** `docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md`
ships `--jobs 8`, where this test did not fail across three CI repetitions per job
and ten container repetitions. The failure is specific to oversubscribing a 3-core
runner 12 ways. It is recorded here because the test is genuinely load-sensitive,
not because it gates that work.

## Scope

- `tests/scripts.bats` -- the `exact socket namespaces survive legacy sanitized-name collisions`
  test. Find the ordering or locking assumption that 12-way concurrency on 3 cores
  breaks, the way the inbox-commit test's fixed 1 s fifo window was found by
  inspection.
- A failure-path dump of the namespace `reconcile.state` and pane `control.state`,
  so the next recurrence carries the evidence this issue asks for.

## Open decisions

- Whether to reproduce locally by running the suite at `--jobs 12` under a CPU
  limit that mimics 3 cores (`docker run --cpus 3`), rather than on a 10-core host
  where 12 jobs is only mild oversubscription.

## Root cause found 2026-08-21: the 5 s harness engine watchdog

The engine-timeout hypothesis this issue recorded under "The socket-namespace
test: investigated, no mechanism found" was right, and it is now backed by a
reproduction rather than by inspection alone.

**The reproduction.** A ten-repetition run of the full post-apply suite as
`bats --jobs 8 --no-parallelize-across-files` inside `docker run --cpus 4` --
two-times CPU oversubscription -- failed once, in repetition 4, on
`herdr-task-sync orders adapter calls by inbox commit rather than invocation start`.
That repetition took 161 s against a ~82 s median for the other nine, so the
container was heavily contended when it failed. The failure is at
`tests/scripts.bats:2457`, the `hts_wait_for_task_slug "$task" invoked-first-committed-second`
that follows the fifo release -- the first invocation exited without ever
committing its slug, and the wait then ran to its ceiling.

**The mechanism.** Every test invocation ran the engine under
`HERDR_TASK_SYNC_TIMEOUT="${HTS_TIMEOUT:-5}"`, and the engine enforces that with
a watchdog subshell that `kill -9`s the engine on expiry
(`run_with_timeout`, home/dot_local/bin/executable_herdr-task-sync:340). Five
seconds was calibrated on an idle machine. Under contention a stubbed engine call
loses that race, gets SIGKILLed mid-call, and the invocation commits nothing --
which is exactly the "slug never written, `hts_wait_for_task_slug` then fails at
its own bound" signature this issue predicted.

Honest limit on the evidence: the failure block shows the missing commit, not the
`kill -9` itself. The signature matches the predicted one; the kill was not
captured directly.

**The same bound was one second from firing by design.** `herdr-task-sync returns
before the naming engine finishes (R8)` (tests/scripts.bats:4201) stubs an engine
that sleeps 4 s on purpose and ran it against the 5 s watchdog. A one-second
margin on an idle machine is not a margin at all under `--jobs`, and R8 is one of
the two tests that accompanied the socket-namespace failure in the CI repetition
recorded above.

**The fix.** `HTS_ENGINE_WATCHDOG_SECONDS` now defaults the test watchdog to 30 s
-- the value `executable_herdr-task-sync:32` itself ships in production -- so the
tests run the shipped hang guard instead of a tightened test-only one. It is a
hang guard, not a budget: every test here stubs the engine, so it should never
fire. The one test that wants it to fire,
`publishes nothing when both engines time out (KTD1)` (tests/scripts.bats:4263),
pins `HTS_TIMEOUT=1` for itself and is unaffected.

This is the third wall-clock-on-an-idle-machine bound found in this file during
the parallel-suite work, after `HERDR_TASK_SYNC_GIT_BUDGET` (0.075 s, SIGKILL)
and the 2 s fail-open assertions. The pattern is worth naming: a `kill -9`
watchdog calibrated against a stub's own sleep is a latent flake, and parallelism
only made the existing gap visible.

**Confirmed.** Twelve repetitions of the same `docker run --cpus 4` /
`--jobs 8` profile after the fix: zero failures, 81–86 s each. The pre-fix run's
161 s outlier is gone with it, which is consistent with the mechanism — a
SIGKILLed engine forces every wait behind it to run to its ceiling.

The remaining ask in this issue is unchanged and unmet: a failure-path dump of
the namespace `reconcile.state` and the pane `control.state`, so the next
recurrence carries its own evidence instead of needing this reconstruction.

## Resolution

Closed 2026-08-21 in `543ca9e` (PR #29). Both tests this issue names are fixed,
and the second one is fixed against a found root cause rather than closed
unreproduced: the harness capped each engine call at 5 s while the shipped script
defaults to 30 s, and the engine enforces that cap with `kill -9`. Under `--jobs`
contention the stubbed engine lost that race, the invocation committed nothing,
and the ordering tests waiting on that commit timed out. The harness now runs the
shipped 30 s watchdog.

Confirmed by twelve repetitions of the full suite at `--jobs 8` inside
`docker run --cpus 4` with zero failures, against one failure in ten repetitions
of the same profile before the fix. The pre-fix run's 161 s outlier disappeared
with the failure, which matches the mechanism — a SIGKILLed engine forces every
wait behind it to run to its ceiling.

**The failure-path state dump this issue asked for was not built, deliberately.**
It existed to diagnose an unknown cause. The cause is now known and a regression
test guards it: `herdr-task-sync ships the timing defaults the tests deliberately
override` reads both shipped values out of the script, so a production change to
either goes red instead of silently un-testing the budget. If a new
load-sensitive flake appears in this file, file it fresh — the general pattern is
tracked in
`docs/issues/2026-08-21-015-capture-the-idle-machine-wall-clock-pattern.md`.
