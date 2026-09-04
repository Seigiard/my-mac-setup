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
  - bashunit
  - herdr
---

# Idle-machine wall-clock bounds are latent test flakes

## Context

> **Where this evidence lives now.** This document was written against `tests/scripts.bats` and the
> `herdr-task-sync` component. The suite migrated to bashunit (`051d3de`) and the component was renamed
> `herdr-pane-labels` (`21aaaf0`), so every `tests/scripts.bats:NNNN` anchor below, and every line number
> attributed to the old harness helper, is historical and resolves only in git history. The **Examples**
> section carries the current addresses, and **Three claims from earlier revisions that no longer hold**
> lists what the tree has since contradicted.

Five incidents exposed one test-design pattern: a wall-clock bound chosen from an idle run can become either a latent flake or a weakened assertion when the suite runs concurrently.

1. **The 1000 ms coordinator envelope measured the wrong work.** The interval included concurrent location probes and a serial presentation tail that accounted for about 78% of the measured window. CPU saturation made the test fail while the probe phase remained concurrent (`2026-08-20-002:41-60`). The current test proves concurrency with an eight-party barrier and uses 30 seconds only as a hang guard (`tests/scripts.bats:2758-2832`).
2. **The 75 ms Git-probe budget killed healthy test stubs.** A forked Bash stub lost the production latency race under `--jobs`, and the pane degraded to stale although no product regression existed (`2026-08-21-024:26-38`). Production still ships the 75 ms user-interface latency budget and enforces it with `kill -9` (`home/dot_local/bin/executable_herdr-pane-labels:82`, `home/dot_local/bin/executable_herdr-pane-labels:636-646`). The current harness gives healthy stub probes a two-second allowance (`tests/helpers/herdr_pane_labels.bash:560`).
3. **The two-second fail-open checks became 20-second checks and lost discrimination.** Two seconds flaked under parallel load, but widening the bound allowed regressions of 3-18 seconds to remain green (`2026-08-21-014:13-44`). This gap remains open: the harness defines a 20-second ceiling, and one test still performs three elapsed-seconds comparisons against it (`tests/helpers/herdr_pane_labels.bash:562-567`, `tests/scripts.bats:1768-1821`). OpenCode independently identified this loss of correctness (session history).
4. **The five-second engine watchdog killed healthy engine calls.** Contention could push a stub beyond the harness-only watchdog. The failure matched the watchdog's `SIGKILL` mechanism: the invocation committed nothing, and a later state wait looked like an ordering defect (`2026-08-20-010:183-231`). The current harness tracks the production 30-second watchdog (`tests/helpers/herdr_pane_labels.bash:569-581`, `home/dot_local/bin/executable_herdr-pane-labels:31-34`).
5. **The 90-second nested-Bats budget covered unrelated parsing and the real assertion.** Bats parsed 196 tests to run one probe, leaving about 1.5x margin on macOS continuous integration and making load expiry indistinguishable from the descriptor regression by exit status alone (`2026-08-21-020:30-68`). Claude Code split the conflated phases, then Pi isolated the probe in a one-test Bats file in PR #55 (session history). The current suite verifies that the probe file contains one test (`tests/scripts.bats:932-938`).

Parallelism did not create these defects. It exposed assumptions that idle execution had hidden. The expensive part of each incident was the misleading signature: a healthy subprocess kill appeared as stale state or missing commits, while a widened bound produced a false green.

## Guidance

**Prefer a causal assertion over elapsed time.** Identify the event or ordering that constitutes the property, then make the forbidden implementation unable to progress. A barrier proves that all workers started concurrently. A release marker proves that one operation completed before another continued. A blocking fixture proves that an entry point returned without waiting for background work. The current ordering test releases its first invocation only after the second invocation commits (`tests/scripts.bats:1839-1865`). The R8 test blocks the engine until release while asserting that the entry point already returned (`tests/scripts.bats:3629-3650`).

**If no causal signal exists, split liveness from behavior.** Use a generous hang guard around setup, parsing, scheduling, and other load-elastic work. Start a separate, tighter assertion only when the event under test begins. Document why a causal form is unavailable. The descriptor test follows this fallback because a held pipe and a released pipe differ only through eventual exit and end-of-file. Its 60-second progress guard ends when the probe publishes its completion signal, while its 30-second exit assertion covers only Bats exit and pipe end-of-file (`tests/helpers/herdr_pane_labels.bash:600-631`, `tests/scripts.bats:1061-1153`).

**Align a true hang guard with production when the test exercises the same mechanism.** A harness-only tightening of the engine watchdog changed what the test exercised and created failures that users would not see. The current 30-second harness value tracks the shipped engine default, and the test that intentionally exercises timeout behavior pins one second locally (`tests/helpers/herdr_pane_labels.bash:569-581`, `tests/scripts.bats:3702-3708`). A static alignment test ensures that a production change cannot silently leave the harness behind (`tests/scripts.bats:3619-3626`).

**Do not force production latency budgets onto slower test doubles.** A forked shell stub can have different timing from real Git. Measure healthy harness runs under realistic contention and give the stub enough time to complete, while separately asserting the shipped production value. The current harness uses two seconds for healthy Git stubs, but the static source test still requires production to ship 75 ms (`tests/helpers/herdr_pane_labels.bash:560`, `tests/scripts.bats:3608-3626`).

**Calibrate against the contention profile that the suite creates.** CPU saturation alone is not a substitute for concurrent process creation, file-descriptor pressure, filesystem work, or runner oversubscription. Ten CPU hogs did not reproduce the engine-watchdog failure, while within-file Bats parallelism did (`2026-08-20-010:133-150`). Run repeated tests with the intended `--jobs` setting and a runner-like CPU limit. Size an assertion from the phase that carries the property, not from the whole test. The current nested driver prints its exit-phase duration on every successful run so later calibration can use green continuous-integration evidence (`tests/scripts.bats:1154-1164`).

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

**Concurrency: replace an envelope with a barrier.** The old form asserted that eight probes plus a
serial tail completed within 1000 ms. The current form is an eight-party barrier that no probe can
clear alone (`tests/bashunit/scripts_test.sh:5805-5837`); the surviving 30-second bound is a pure hang
guard. The test's own comment records why the envelope was wrong: the window it measured was ~78%
serial presentation tail, so it went red on slower runners with no regression behind it.

**Git probes: calibrate the harness against the stub, not the shipped budget.** Production keeps its
75 ms user-interface budget (`home/dot_local/bin/executable_herdr-pane-labels:59`), while
location-oriented tests route forked shell stubs through a two-second harness budget
(`tests/helpers/herdr_pane_labels.bash:674`), whose comment states the reasoning: "a tighter budget
would SIGKILL those, which is the failure this value exists to prevent."

**Liveness and behaviour are separate constants, and the derived one stays honest.** The nested-suite
driver waits up to 60 seconds for a progress signal — "PROGRESS is the hang guard"
(`tests/helpers/herdr_pane_labels.bash:709`) — and gives exit a separate 30-second assertion — "EXIT
is the assertion, and the only bound here that can fire on a healthy run" (`:717`). The non-vacuity
ceiling is computed from both rather than hand-picked (`:742`), because "a hand-picked number silently
inverts the first time either bound above moves." The poll ceiling carries the same scar: 60 seconds,
after 10 and 15 "were calibrated on an idle machine" (`:684`).

**Probe isolation.** The outer suite runs one-test probe files
(`tests/bashunit/herdr_pane_labels_descriptor_probe_test.sh`,
`herdr_child_descriptor_probe_test.sh`, `bashunit_late_output_probe_test.sh`) and its driver refuses
to pass unless exactly one test ran (`tests/bashunit/scripts_test.sh:4601-4690`), with distinct
assertion messages per failure mode rather than one numeric timeout status.

### Three claims from earlier revisions that no longer hold

The suite this document was written against was `tests/scripts.bats`, and its subject component was
`herdr-task-sync`. Both are gone — the suite migrated to bashunit (`051d3de`) and the component was
renamed `herdr-pane-labels` (`21aaaf0`) — so every `tests/scripts.bats:NNNN` anchor in earlier
revisions of this document is unrecoverable. Three specific claims were checked against the current
tree and are false:

1. **"A static source test still requires production to ship 75 ms."** No test asserts `0.075`. The
   production literal survives at `executable_herdr-pane-labels:59`; the alignment assertion does not.
2. **"The harness and production both use 30 seconds for ordinary engine calls, and a static
   alignment test keeps them together."** `executable_herdr-pane-labels` has no timeout constant at
   all. The analogous constant moved to a different component — `executable_herdr-worktree-identity:17`,
   `ENGINE_TIMEOUT="${HERDR_WORKTREE_IDENTITY_TIMEOUT:-30}"` — and no test asserts that alignment.
3. **"This gap remains open: three elapsed-seconds comparisons against a 20-second fail-open
   ceiling."** No such constant and no such comparison exist. Whether the gap was closed deliberately
   or deleted with the harness cannot be determined from the tree, because the issue that tracked it
   (`2026-08-21-014`) was removed in the closed-issue cleanup.

Guidance 3 ("align a true hang guard with production when the test exercises the same mechanism") is
therefore currently unimplemented: the one place it would apply, `ENGINE_TIMEOUT`, has no guard.

## Related

- `2026-08-21-015` - source issue that consolidates the five incidents and the causal-first rule.
- `2026-08-20-002` - coordinator-envelope diagnosis, causal barrier repair, and serial-spawn mutation.
- `2026-08-20-010` - fixed-sleep ordering repair and engine-watchdog diagnosis.
- `2026-08-21-014` - unresolved correctness gap in the widened fail-open checks.
- `2026-08-21-020` - nested-Bats failure analysis, split-bound fallback, signatures, and non-vacuity rehearsal.
- `2026-08-21-021` - extraction of the descriptor probe into a one-test file.
- `2026-08-21-024` - Git-budget failure and starvation rehearsal.
- `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md:70-76` - sibling pattern for external agent subprocesses: separate liveness from wall-clock budget and calibrate from healthy runs.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-20-002`,
  `2026-08-20-010`, `2026-08-21-014`, `2026-08-21-015`, `2026-08-21-020`, `2026-08-21-021`,
  `2026-08-21-024`. All were removed in the closed-issue cleanup; the evidence they carried is
  reproduced inline above.
- `docs/issues/2026-09-02-013-palette-herdr-stub-tests-flake-under-parallel-load-on-a-busy-machine.md`
  — open, and classified by this pattern: 1, 6, 5 and 7 failures across four consecutive
  `tests/lib/bashunit -j 8` runs with four coding agents running concurrently (load average 10-16).
