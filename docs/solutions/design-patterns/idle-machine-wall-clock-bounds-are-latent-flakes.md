---
title: Idle-machine wall-clock bounds are latent test flakes
date: 2026-08-23
category: design-patterns
module: herdr
problem_type: design_pattern
component: testing_framework
severity: high
related_components:
  - tooling
applies_when:
  - "A test uses elapsed wall time to prove ordering, concurrency, prompt return, or fail-open behavior"
  - "A timeout calibrated on an idle machine also runs under parallel CI load or scheduler contention"
  - "One deadline serves both as a hang guard and as a behavioral or performance assertion"
  - "A test-only timeout shadows a production watchdog or subprocess budget"
  - "A timeout failure erases causal evidence and makes a later wait fail elsewhere"
symptoms:
  - "A test passes in focused idle runs but fails under parallel CI load without a product regression"
  - "A healthy subprocess is killed at its deadline and a downstream assertion reports missing state or incorrect ordering"
  - "Widening one timeout removes flakes but also lets the regression that the test was meant to catch pass"
tags:
  - wall-clock
  - latent-flake
  - test-timeout
  - hang-guard
  - causal-testing
  - parallel-ci
  - bats
  - herdr
---

# Idle-machine wall-clock bounds are latent test flakes

## Context

Five incidents exposed one test-design pattern: a wall-clock bound chosen from an idle run can become either a latent flake or a weakened assertion when the suite runs concurrently.

1. **The 1000 ms coordinator envelope measured the wrong work.** The interval included concurrent location probes and a serial presentation tail that accounted for about 78% of the measured window. CPU saturation made the test fail while the probe phase remained concurrent (`docs/issues/2026-08-20-002-coordinator-location-test-flake.md:41-60`). The current test proves concurrency with an eight-party barrier and uses 30 seconds only as a hang guard (`tests/scripts.bats:2758-2832`).
2. **The 75 ms Git-probe budget killed healthy test stubs.** A forked Bash stub lost the production latency race under `--jobs`, and the pane degraded to stale although no product regression existed (`docs/issues/2026-08-21-024-sweep-location-test-runs-the-75ms-production-git-budget.md:26-38`). Production still ships the 75 ms user-interface latency budget and enforces it with `kill -9` (`home/dot_local/bin/executable_herdr-task-sync:82`, `home/dot_local/bin/executable_herdr-task-sync:636-646`). The current harness gives healthy stub probes a two-second allowance (`tests/helpers/herdr_task_sync.bash:560`).
3. **The two-second fail-open checks became 20-second checks and lost discrimination.** Two seconds flaked under parallel load, but widening the bound allowed regressions of 3-18 seconds to remain green (`docs/issues/2026-08-21-014-fail-open-assertions-no-longer-catch-a-slow-fail-open.md:13-44`). This gap remains open: the harness defines a 20-second ceiling, and one test still performs three elapsed-seconds comparisons against it (`tests/helpers/herdr_task_sync.bash:562-567`, `tests/scripts.bats:1768-1821`). OpenCode independently identified this loss of correctness (session history).
4. **The five-second engine watchdog killed healthy engine calls.** Contention could push a stub beyond the harness-only watchdog. The failure matched the watchdog's `SIGKILL` mechanism: the invocation committed nothing, and a later state wait looked like an ordering defect (`docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md:183-231`). The current harness tracks the production 30-second watchdog (`tests/helpers/herdr_task_sync.bash:569-581`, `home/dot_local/bin/executable_herdr-task-sync:31-34`).
5. **The 90-second nested-Bats budget covered unrelated parsing and the real assertion.** Bats parsed 196 tests to run one probe, leaving about 1.5x margin on macOS continuous integration and making load expiry indistinguishable from the descriptor regression by exit status alone (`docs/issues/2026-08-21-020-inner-bats-budget-flaked-the-macos-job.md:30-68`). Claude Code split the conflated phases, then Pi isolated the probe in a one-test Bats file in PR #55 (session history). The current suite verifies that the probe file contains one test (`tests/scripts.bats:932-938`).

Parallelism did not create these defects. It exposed assumptions that idle execution had hidden. The expensive part of each incident was the misleading signature: a healthy subprocess kill appeared as stale state or missing commits, while a widened bound produced a false green.

## Guidance

**Prefer a causal assertion over elapsed time.** Identify the event or ordering that constitutes the property, then make the forbidden implementation unable to progress. A barrier proves that all workers started concurrently. A release marker proves that one operation completed before another continued. A blocking fixture proves that an entry point returned without waiting for background work. The current ordering test releases its first invocation only after the second invocation commits (`tests/scripts.bats:1839-1865`). The R8 test blocks the engine until release while asserting that the entry point already returned (`tests/scripts.bats:3629-3650`).

**If no causal signal exists, split liveness from behavior.** Use a generous hang guard around setup, parsing, scheduling, and other load-elastic work. Start a separate, tighter assertion only when the event under test begins. Document why a causal form is unavailable. The descriptor test follows this fallback because a held pipe and a released pipe differ only through eventual exit and end-of-file. Its 60-second progress guard ends when the probe publishes its completion signal, while its 30-second exit assertion covers only Bats exit and pipe end-of-file (`tests/helpers/herdr_task_sync.bash:600-631`, `tests/scripts.bats:1061-1153`).

**Align a true hang guard with production when the test exercises the same mechanism.** A harness-only tightening of the engine watchdog changed what the test exercised and created failures that users would not see. The current 30-second harness value tracks the shipped engine default, and the test that intentionally exercises timeout behavior pins one second locally (`tests/helpers/herdr_task_sync.bash:569-581`, `tests/scripts.bats:3702-3708`). A static alignment test ensures that a production change cannot silently leave the harness behind (`tests/scripts.bats:3619-3626`).

**Do not force production latency budgets onto slower test doubles.** A forked shell stub can have different timing from real Git. Measure healthy harness runs under realistic contention and give the stub enough time to complete, while separately asserting the shipped production value. The current harness uses two seconds for healthy Git stubs, but the static source test still requires production to ship 75 ms (`tests/helpers/herdr_task_sync.bash:560`, `tests/scripts.bats:3608-3626`).

**Calibrate against the contention profile that the suite creates.** CPU saturation alone is not a substitute for concurrent process creation, file-descriptor pressure, filesystem work, or runner oversubscription. Ten CPU hogs did not reproduce the engine-watchdog failure, while within-file Bats parallelism did (`docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md:133-150`). Run repeated tests with the intended `--jobs` setting and a runner-like CPU limit. Size an assertion from the phase that carries the property, not from the whole test. The current nested driver prints its exit-phase duration on every successful run so later calibration can use green continuous-integration evidence (`tests/scripts.bats:1154-1164`).

**Give each failure mode a distinct signature.** A timeout code alone can conflate load, an early test failure, a vacuous fixture, and the guarded regression. Assign separate statuses or messages where the causes diverge. The nested driver reserves status 124 for failure to reach the completion signal, 125 for the descriptor regression, 3 for early completion, 4 for a vacuous fixture, 5 for a stuck detached worker, and 7 for a nested-test failure (`tests/scripts.bats:982-991`).

**Prove that the test can fail for the intended reason.** Apply a targeted mutation that introduces the regression, and add a non-vacuity assertion for every fixture premise. The R8 test verifies that the controlled engine started but had not completed before release (`tests/scripts.bats:3642-3649`). The descriptor driver checks a durable give-up marker and the blocking process itself, rather than an ancestor that can outlive the block (`tests/scripts.bats:1166-1203`). A companion test forces the fixture to give up immediately and requires the outer test to fail (`tests/scripts.bats:1242-1252`).

## Why This Matters

A test bound has two independent error modes. If it is too tight for healthy contended execution, it creates flakes. If engineers widen it without preserving the behavioral threshold, it creates false greens. One number cannot reliably serve both roles when scheduler delay and product behavior occupy the same interval.

Causal assertions remove machine speed from the verdict. A deliberately serial coordinator cannot satisfy an all-workers barrier, and an entry point that waits synchronously cannot return while its controlled engine remains blocked. These failures identify the violated contract directly instead of asking whether a duration was unusual.

When a clock remains necessary, phase separation preserves meaning. A generous guard answers "did setup or progress stop entirely?" A measured assertion answers "did the behavior complete within its contract?" Distinct statuses then keep a load failure, fixture failure, and product regression from sending investigation into the wrong subsystem.

Mutation and non-vacuity checks prevent sophisticated harnesses from becoming decorative. A green test is evidence only if the causal premise occurred, the test observes the process that carries that premise, and a deliberate regression makes the expected assertion fail.

## When to Apply

- A test uses `sleep`, elapsed wall time, polling ceilings, subprocess timeouts, watchdogs, or delayed fixture release.
- A test passes alone but fails under `--jobs`, runner oversubscription, process-heavy suites, or file-descriptor contention.
- A timeout kills work, and the later failure appears as missing state, stale output, an ordering violation, or another downstream symptom.
- A timeout increase fixes a flake but also permits behavior that the original test intended to reject.
- A nested runner or helper performs substantial setup before reaching the property under test.
- A fixture can give up, exit, or release its resource before the assertion observes it.
- A test override differs from a shipped production timeout or latency budget.

## Examples

**Concurrency: replace an envelope with a barrier.** The old form asserted that eight probes plus a serial tail completed within 1000 ms. The current form requires all eight probes to publish markers before any probe can continue, so a serial implementation deadlocks before release. Thirty seconds only limits a broken test run (`tests/scripts.bats:2800-2832`). The historical serial-spawn mutation failed after the timer was removed, which confirmed that the barrier was not vacuous (`docs/issues/2026-08-20-002-coordinator-location-test-flake.md:55-60`).

**Git probes: calibrate the harness and preserve the shipped contract.** Production keeps its 75 ms user-interface budget, while location-oriented tests route shell stubs through the measured two-second harness budget (`home/dot_local/bin/executable_herdr-task-sync:82`, `tests/helpers/herdr_task_sync.bash:560`). A static test checks the production literal without racing a real 75 ms clock (`tests/scripts.bats:3608-3626`).

**Fail-open paths: do not call a widened guard a behavioral deadline.** The current three checks permit 20 seconds (`tests/helpers/herdr_task_sync.bash:562-567`, `tests/scripts.bats:1768-1821`). Until those paths gain a causal signal or a separately calibrated behavioral deadline, describe them only as hang detection. A repair is incomplete unless a delay that should violate the contract fails the test.

**Engine calls: mirror the production watchdog and override only the timeout test.** The harness and production both use 30 seconds for ordinary engine calls (`tests/helpers/herdr_task_sync.bash:569-581`, `home/dot_local/bin/executable_herdr-task-sync:31-34`). The timeout-specific test sets `HTS_TIMEOUT=1`, so intentional watchdog coverage remains fast and explicit (`tests/scripts.bats:3702-3708`).

**Nested Bats: isolate setup, split phases, and name causes.** The outer suite verifies that the nested target has exactly one test (`tests/scripts.bats:932-938`). The driver waits up to 60 seconds for the probe's completion signal, then gives exit and pipe end-of-file a separate 30-second assertion (`tests/helpers/herdr_task_sync.bash:600-631`, `tests/scripts.bats:1081-1153`). It refuses to pass if the blocking fixture gave up (`tests/scripts.bats:1166-1203`).

## Related

- `docs/issues/2026-08-21-015-capture-the-idle-machine-wall-clock-pattern.md` - source issue that consolidates the five incidents and the causal-first rule.
- `docs/issues/2026-08-20-002-coordinator-location-test-flake.md` - coordinator-envelope diagnosis, causal barrier repair, and serial-spawn mutation.
- `docs/issues/2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md` - fixed-sleep ordering repair and engine-watchdog diagnosis.
- `docs/issues/2026-08-21-014-fail-open-assertions-no-longer-catch-a-slow-fail-open.md` - unresolved correctness gap in the widened fail-open checks.
- `docs/issues/2026-08-21-020-inner-bats-budget-flaked-the-macos-job.md` - nested-Bats failure analysis, split-bound fallback, signatures, and non-vacuity rehearsal.
- `docs/issues/2026-08-21-021-nested-bats-run-parses-the-whole-suite.md` - extraction of the descriptor probe into a one-test file.
- `docs/issues/2026-08-21-024-sweep-location-test-runs-the-75ms-production-git-budget.md` - Git-budget failure and starvation rehearsal.
- `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md:70-76` - sibling pattern for external agent subprocesses: separate liveness from wall-clock budget and calibrate from healthy runs.
