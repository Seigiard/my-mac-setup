---
title: Bats mid-test compound conditionals bypass errexit
date: 2026-08-28
category: test-failures
module: testing
problem_type: test_failure
component: testing_framework
symptoms:
  - "A Bats test remains green after a standalone [[ ... ]] or (( ... )) condition evaluates false before a later successful command"
  - "Assertions that reviewers believe are enforced do not invoke the Bats ERR trap under macOS system Bash 3.2"
root_cause: logic_error
resolution_type: test_fix
severity: high
related_components:
  - "development_workflow"
  - "tooling"
tags:
  - bats
  - bash-3-2
  - errexit
  - err-trap
  - compound-conditionals
  - test-integrity
  - semantic-regression-tests
  - linting
---

# Bats mid-test compound conditionals bypass errexit

## Problem

On macOS Bash 3.2, a false standalone `[[ ... ]]` or `(( ... ))` command in the middle of a Bats 1.14 test function can bypass Bats' implicit failure machinery. If a later command succeeds, the generated test function returns zero and Bats reports a false green.

## Symptoms

- A Bats test remained green after a mid-test `[[ ... ]]` condition was changed to an always-false expression.
- The same assertion appeared enforced as the final command, then became inert when a successful command was added after it.
- A query-bound assertion failed in Linux Docker but was provably unenforced under the repository's local macOS Bash 3.2 and Bats 1.14 combination.
- The suite contained 29 first-party standalone compound conditionals whose apparent assertions depended on implicit shell behavior.

This unsafe shape looks like an assertion but has no explicit failure path:

```bash
@test "returns the expected value" {
  actual="$(produce_value)"
  [[ "$actual" == "expected" ]]
  printf 'checked\n'
}
```

## What Didn't Work

No separate failed implementation attempts were recorded. These implicit safeguards were insufficient:

- Relying on Bats' `set -eET` and `ERR` trap did not enforce a false mid-function `[[ ... ]]` or `(( ... ))` under macOS Bash 3.2.
- Relying on final-command position was fragile. A false compound conditional at the end failed empirically, but adding any later successful command changed the verdict to green.
- ShellCheck could not enforce this Bats-specific semantic contract. The conditionals are valid shell syntax.
- Linux-only behavior was not representative. The assertion could fail in Docker while remaining inert on the supported macOS shell.

## Solution

Convert standalone compound-conditional assertions to explicit failure paths with useful diagnostics:

```bash
# Before: a later successful command can erase this false status on Bash 3.2.
[[ "$actual" == "expected" ]]

# After: failure is explicit and reports the observed value.
[[ "$actual" == "expected" ]] || fail "unexpected value: $actual"
```

Arithmetic assertions follow the same rule:

```bash
(( count > 0 )) || fail "expected a positive count: $count"
```

PR [#91](https://github.com/Seigiard/my-mac-setup/pull/91) converted all 29 first-party standalone checks and added `scripts/check_bats_assertions.py` to `make lint`. The checker recursively inspects first-party `.bats` files and rejects covered `[[ ... ]]` and `(( ... ))` command shapes without explicit status handling. It excludes vendored Bats libraries and distinguishes executable conditionals from quoted text, comments, heredocs, here-strings, arithmetic expansions, multiline conditionals, and normal `if` or `while` control flow.

The checker resumes after each recognized compound conditional and inspects later same-line command segments. `2026-08-28-004` records the regression coverage that prevents an explicitly handled first conditional from hiding a later bare conditional.

Behavioral tests in `tests/test_bats_assertion_contract.py` prove both sides of the checker contract. Unsafe fixtures return nonzero with file and line diagnostics, while explicit handlers, control flow, shell payloads, and vendored fixtures remain accepted. Each converted assertion was also calibrated with an always-false mutation and observed failing at its new handler before its real condition was restored.

## Why This Works

The quirk is a property of **macOS system Bash 3.2**, not of any particular test runner, which is why
it survived this repository's migration off bats. Under a runner that installs an `ERR` trap and
relies on the test body's final exit status:

1. The test body executes a false mid-body `[[ ... ]]` or `(( ... ))` command.
2. Bash 3.2 neither exits nor invokes the inherited `ERR` trap for that compound conditional in this
   position.
3. Execution continues to the next command.
4. A later successful command becomes the body's final status.
5. The runner sees a zero final status and reports the test as passing.

This held under bats, whose `bats-exec-test` ran generated `@test` functions under `set -eET`, and it
holds today under the house DSL. `tests/bashunit/test-dsl.bash:16-21` documents the inheritance
explicitly, and names this document as the reason:

> Failure detection is an ERR trap with errtrace (`set -E`, no errexit) plus the body's final exit
> status. This matches bats' `set -eET` on the same interpreter — helper-depth command failures fail
> the test, while the bash-3.2 quirk stays: a mid-body `[[ ]]`/`(( ))` false is inert.

The DSL installs that trap as `_BATS_ERR_TRAP` (`test-dsl.bash:37`, armed at `:59` and `:129`). Because
it deliberately reproduces bats' semantics on the same interpreter, it reproduces this defect too.

With `[[ ... ]] || fail "..."`, false selects the explicit failure branch. `fail` returns nonzero with
a useful diagnostic, so the test no longer depends on Bash preserving the compound conditional's
intermediate status. `fail` still exists in the DSL with bats-support semantics, so the prescribed fix
is unchanged.

This bug is specific to the compound conditional commands tested here. A false simple `[ ... ]` command
in the same mid-function position was empirically observed to trigger `ERR` and `errexit` under macOS
Bash 3.2. The lint guard therefore targets standalone `[[ ... ]]` and `(( ... ))`, not every `[` simple
command. Explicit assertion helpers or `|| fail` are still preferable whenever a command is intended to
communicate an assertion.

> **Naming note.** The title and slug of this document say "Bats" because bats was the runner when the
> defect was found. The repository migrated to bashunit in `051d3de`; the defect, the guard, and the fix
> are unchanged. The slug is retained because `tests/bashunit/test-dsl.bash` and
> `scripts/check_bats_assertions.py` both cite this file by path.

## Prevention

- Give every standalone `[[ ... ]]` and `(( ... ))` assertion an explicit handler such as `|| fail "diagnostic"`, or use an appropriate `assert_*` helper.
- Keep `python3 scripts/check_bats_assertions.py tests` in `make lint` as defense in depth for its covered syntax, and preserve regression issues for any newly discovered parser gap.
- Calibrate assertion changes by recreating the regression: observe an always-false form fail, restore the real condition, then observe the same test pass.
- Keep rejection fixtures beside valid controls so the guard proves it recognizes executable conditionals without rejecting control flow, generated shell payloads, or vendored tests.
- Run macOS and Linux gates because shell-version differences are part of the supported environment, not interchangeable evidence.

Verification recorded when the fix landed (2026-08-28, on the then-current bats suite): `make test-issues`
44 tests, `make lint`, all 14 affected test bodies after restoring their real conditions, and
`make test-ubuntu` at 403 cases with expected skips. Those counts have moved since the bashunit
migration and are kept as the historical record, not as current expected values.

The guard's scope grew with the migration. `scripts/check_bats_assertions.py:229-247` now globs
`bashunit/*_test.sh`, `helpers/*.bash` and `bashunit/*.bash` alongside any remaining `*.bats`, with the
comment "`.bats` files disappear in a later migration stage; their absence is fine." It scans whole
files rather than only `test_*` bodies, because helpers run in the same test context.

## Related Issues

- `2026-08-27-002` records the repository issue and resolution.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-27-002`, `2026-08-28-004`.
  Both files were removed in the closed-issue cleanup.
- `2026-08-28-004` records the resolved same-line false negative.
- [PR #91: Enforce Bats conditional assertions](https://github.com/Seigiard/my-mac-setup/pull/91) contains the implementation and verification evidence.
- [`semantic-regression-tests-over-source-shape.md`](../design-patterns/semantic-regression-tests-over-source-shape.md) defines the broader red/green calibration and behavioral-control pattern used here.
