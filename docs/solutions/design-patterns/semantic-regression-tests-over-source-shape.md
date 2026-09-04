---
title: Semantic regression tests over source shape
date: 2026-08-24
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - ci
  - chezmoi
applies_when:
  - "Adding a regression test for a behavior that already has neighboring coverage"
  - "Reviewing tests that grep source code or assert implementation-specific strings"
  - "Building fixtures for validators, event aggregation, or subprocess behavior"
  - "Choosing between a focused command and the repository's canonical test gate"
  - "Reporting a suite with skipped, stalled, or only individually passing tests"
symptoms:
  - "A test stays green after the protected behavior is removed"
  - "A subprocess error message satisfies an output assertion because status was never checked"
  - "A fixture called valid never reaches the success path it claims to exercise"
  - "A required package is declared or installed, but the process running the gate cannot resolve its binary"
  - "A partial or isolated run is reported as proof that the complete suite passed"
tags:
  - semantic-tests
  - regression-tests
  - behavior-testing
  - source-shape
  - control-fixtures
  - coverage-ownership
  - bashunit
---

# Semantic regression tests over source shape

## Context

A test-suite audit found many green checks but less independent evidence than the pass count implied. Some tests searched source files for method names or wiring strings, several repeated facts already enforced by TypeScript or a stronger neighboring test, and some subprocess assertions inspected output without first proving the command succeeded. Other fixtures carried a success-oriented name while never reaching the validator or aggregation branch they claimed to cover.

The audit also found verification drift. Different CI and Docker paths invoked selected Smithers commands directly, so a green path could omit the frozen install, secret scan, typecheck, or part of the Bun suite. At the repository level, `make test-suite` can pass while testing the already-deployed home directory rather than an unapplied checkout. A complete run of the full script suite then stalled even though the blocked test passed alone, demonstrating that isolated success is not a suite verdict. (That suite has since migrated from bats to bashunit; the audit's Smithers examples describe a codebase that was removed on 2026-09-01, but the pattern is unchanged.)

These failures share one cause: the check proves that some implementation shape or execution fragment exists, not that the intended contract survives regression.

## Guidance

A **semantic regression test** changes verdict with the protected behavior: red when the regression is present, green when the behavior is correct. Its completion criterion is evidence of both states, not the presence of a new test case.

### Start from the contract

Name the externally observable contract before choosing an assertion. Prefer the lowest stable boundary that a consumer can observe:

- Call the function and assert its result or side effect.
- Run the command and assert its exit status before stdout or stderr.
- Render or deploy the template and inspect the resulting file.
- Query the real persistence boundary when aggregation or ownership semantics live in the database.

Literal source assertions are appropriate only when literal shape is itself the contract. Examples include reserved command syntax that must survive templating, a required symlink target, or policy text consumed verbatim by another tool. A grep for an internal method call, type annotation, or helper name proves implementation shape instead of behavior; a refactor can break it while preserving behavior, and removing the behavior can leave the matching text behind.

### Prove the red state

For a new regression test, demonstrate that the intended regression makes the test fail. Use the cheapest faithful method:

1. Run the test against the known-bad parent revision when it contains the regression.
2. Temporarily make the smallest production mutation that recreates the regression.
3. For a validator or fixture bug, run the fixture through the real boundary and show that the old fixture cannot distinguish the bad path.

Restore the corrected implementation, rerun the same test, and require green. A test that was observed only in the green state remains uncalibrated: it may be useful, but it has not proved regression sensitivity.

### Build discriminating controls

A fixture proves a branch only when nearby controls isolate the property under test:

- A rejection fixture needs a minimally different valid fixture that reaches success.
- An aggregation fixture needs related and unrelated records, including collision-prone identifiers such as shared prefixes.
- An event filter needs a same-entity wrong-event control, not only a different entity.
- A timeout or concurrency test needs proof that it observed the intended process state rather than startup or cleanup noise.

Controls turn a plausible example into a discriminator. Without them, the fixture can pass because every input follows the same accidental path.

### Give each contract one owner

Search existing tests before adding coverage. Choose the narrowest suite that can observe the complete contract, then strengthen that case:

- Unit tests own pure function and validator semantics.
- Template tests own rendered output across configuration branches.
- Deployment or idempotency tests own filesystem effects after `chezmoi apply`.
- Smoke tests own deployed cross-component behavior that no narrower suite can prove.
- TypeScript and lint gates own type and static-analysis guarantees.

Repeating the same assertion in smoke, template, and unit suites does not create three independent proofs. It creates three maintenance sites with correlated blind spots. Keep additional layers only when each catches a distinct failure mode.

### Preserve gate integrity

Use the smallest canonical `make` target that covers the changed contract. A canonical target owns setup and the complete sequence; manually invoking its components is a different gate even when the visible test command matches.

For managed files under `home/`, `make test-ubuntu` applies the checkout inside a disposable environment. `make test-suite` is host-safe by design and observes the already-deployed home directory, so it cannot prove an unapplied managed-file change.

**The negative-assertion case is now mechanized.** `home/dot_local/bin/executable_test-oracle-guard`
is a deployed gate — shared by a Claude Code hook, an opencode plugin and a pi extension — that
inspects proposed edits to test files and flags assertions of *absence*, because those usually
restate the patch that removed a string instead of protecting behavior. Its header names this
document as the standard it enforces. The escape hatch is an `oracle:` comment on or just above the
flagged line, naming the independent oracle; the gate fails open so a broken guard never blocks an
agent. Its behavioral coverage is `tests/bashunit/oracle_guard_test.sh`. A known gap is open:
`docs/issues/2026-09-02-011-test-oracle-guard-misses-positive-tautological-tests.md` — the guard
catches tautological *negative* assertions but not tautological positive ones.

Dependency presence is not command reachability. Verify required binaries from the exact process that runs the gate. A package declaration, a successful installer log, or a `shellenv` export in an earlier subprocess does not prove that a later CI step can resolve the command.

Check what actually ran as well as its exit code. Skips can remove coverage while preserving green, and a partial run can stop before the relevant test. When dependencies or environments change, compare skip identities and reasons rather than only pass counts.

### Report incomplete evidence honestly

A stalled full suite and a passing isolated test are two separate observations:

- The isolated result narrows the cause away from a deterministic failure in that test alone.
- The stalled suite remains incomplete because ordering, leaked state, contention, or cleanup can exist only in the full run.

Record the last completed test, the test active at the boundary, elapsed time, process state, and isolated reproduction result. Create a repository issue for unresolved behavior. Report only the checks that completed; never promote an isolated pass into a full-suite verdict.

## Why This Matters

A false green is more dangerous than an obvious missing test because it looks like evidence and suppresses further investigation. Source-shape assertions, duplicate coverage, inaccessible dependencies, and partial runs all inflate confidence without adding an independent verdict on behavior.

Semantic ownership also lowers maintenance cost. One calibrated test at the correct boundary survives internal refactors, fails for the regression it names, and gives canonical gates one authoritative path to execute.

## Examples

The 2026-08-24 audit applied these rules in several forms:

- Source-grep smoke checks for Smithers type and wiring details were removed because `tsc --noEmit` and behavior tests own those contracts.
- Validator success fixtures were changed to satisfy the real success contract instead of merely avoiding one rejection branch.
- Cost aggregation moved to real SQLite-backed events with child, unrelated, shared-prefix, and wrong-event controls.
- Platform subprocess checks now require successful status before accepting output.
- Repeated apply/idempotency paths were consolidated under one state-transition owner.
- The stalled full-suite run was reported as incomplete even though its active test passed in isolation.
  (That suite was `tests/scripts.bats`; it is now `tests/bashunit/scripts_test.sh` after the bashunit migration.)

The important result is not fewer tests by itself. The resulting suite has fewer assertions whose verdict can remain green while the protected behavior is absent.

## When to Apply

Apply this pattern whenever a test is added, changed, reviewed, or used as release evidence. It is especially important for source-grep tests, subprocess wrappers, validators, event aggregators, generated configuration, test suites with skip guards, and repositories with multiple CI entry points.

Do not replace exact-format contract tests merely because they inspect text. First decide whether consumers depend on the exact text. If they do, render or deploy through the real producer and assert that contract at its consumption boundary.

## Related

- `skip-set-parity-proves-reduced-dependencies.md` — why a green suite does not prove unchanged coverage when skips can expand.
- `completion-is-not-a-verdict.md` — why execution completion and an acceptance verdict are separate states.
- `idle-machine-wall-clock-bounds-are-latent-flakes.md` — why timing observations need a bounded, state-aware contract.
- `2026-08-24-001` — the full-suite stall discovered during the audit. Closed and compounded into
  `outliving-processes-hang-the-suite.md`, which owns that failure class; the issue file was removed
  in the closed-issue cleanup.
- `outliving-processes-hang-the-suite.md` — the sibling class: a suite that never returns rather than
  one that returns a dishonest verdict.
