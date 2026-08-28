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

The checker resumes after each recognized compound conditional and inspects later same-line command segments. [`2026-08-28-004`](../../issues/2026-08-28-004-bats-assertion-checker-misses-a-second-same-line-conditional.md) records the regression coverage that prevents an explicitly handled first conditional from hiding a later bare conditional.

Behavioral tests in `tests/test_bats_assertion_contract.py` prove both sides of the checker contract. Unsafe fixtures return nonzero with file and line diagnostics, while explicit handlers, control flow, shell payloads, and vendored fixtures remain accepted. Each converted assertion was also calibrated with an always-false mutation and observed failing at its new handler before its real condition was restored.

## Why This Works

Bats preprocesses each `@test` block into a generated Bash function. Conceptually, the unsafe example becomes:

```bash
bats_test_function --description "returns the expected value" -- test_returns_the_expected_value
test_returns_the_expected_value() {
  actual="$(produce_value)"
  [[ "$actual" == "expected" ]]
  printf 'checked\n'
}
```

`bats-exec-test` starts with `set -eET`, installs Bats' `ERR` trap, and invokes the generated function from `bats_perform_test`. The verified causal chain on macOS Bash 3.2 is:

1. The generated function executes a false mid-function `[[ ... ]]` or `(( ... ))` command.
2. Bash 3.2 neither exits nor invokes the inherited `ERR` trap for that compound conditional in this position.
3. Execution continues to the next command.
4. A later successful command becomes the function's final status.
5. Bats reaches `BATS_TEST_COMPLETED=1` and reports the test as passing.

With `[[ ... ]] || fail "..."`, false selects the explicit failure branch. `fail` returns nonzero with a useful diagnostic, so the test no longer depends on Bash preserving the compound conditional's intermediate status.

This bug is specific to the compound conditional commands tested here. A false simple `[ ... ]` command in the same mid-function position was empirically observed to trigger `ERR` and `errexit` under macOS Bash 3.2. The lint guard therefore targets standalone `[[ ... ]]` and `(( ... ))`, not every `[` simple command. Explicit assertion helpers or `|| fail` are still preferable whenever a command is intended to communicate an assertion.

## Prevention

- Give every standalone `[[ ... ]]` and `(( ... ))` assertion an explicit handler such as `|| fail "diagnostic"`, or use an appropriate `assert_*` helper.
- Keep `python3 scripts/check_bats_assertions.py tests` in `make lint` as defense in depth for its covered syntax, and preserve regression issues for any newly discovered parser gap.
- Calibrate assertion changes by recreating the regression: observe an always-false form fail, restore the real condition, then observe the same test pass.
- Keep rejection fixtures beside valid controls so the guard proves it recognizes executable conditionals without rejecting control flow, generated shell payloads, or vendored tests.
- Run macOS and Linux gates because shell-version differences are part of the supported environment, not interchangeable evidence.

Verification for the fix completed successfully:

- `make test-issues`: 44 tests.
- `make lint`.
- All 14 affected Bats test bodies after restoring their real conditions.
- `make test-ubuntu`: 403 cases with expected skips.

## Related Issues

- [`docs/issues/2026-08-27-002-bare-mid-test-assertions-are-silently-inert-in-bats.md`](../../issues/2026-08-27-002-bare-mid-test-assertions-are-silently-inert-in-bats.md) records the repository issue and resolution.
- [`docs/issues/2026-08-28-004-bats-assertion-checker-misses-a-second-same-line-conditional.md`](../../issues/2026-08-28-004-bats-assertion-checker-misses-a-second-same-line-conditional.md) records the resolved same-line false negative.
- [PR #91: Enforce Bats conditional assertions](https://github.com/Seigiard/my-mac-setup/pull/91) contains the implementation and verification evidence.
- [`semantic-regression-tests-over-source-shape.md`](../design-patterns/semantic-regression-tests-over-source-shape.md) defines the broader red/green calibration and behavioral-control pattern used here.
