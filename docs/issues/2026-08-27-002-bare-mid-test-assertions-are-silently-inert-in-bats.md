---
title: "Bare mid-test [[ ]] assertions are silently inert in bats"
short_description: "All 29 first-party standalone [[...]] checks now use explicit failure paths, and a tested lint checker rejects future bare [[...]] and ((...)) commands while excluding vendored suites and shell payloads."
type: "bug"
category: "testing-ci"
tags: ["test-integrity"]
date: "2026-08-27"
status: "done"
priority: "medium"
closed: "2026-08-28"
---

## Why this exists

Under this repo's bash/bats combination, a bare `[[ ... ]]` assertion that is not the last statement of a `@test` body returns false without failing the test — bats' errexit propagation does not fire for it mid-function. This was discovered twice independently during the git-status-playground work: a query-bound assertion in `tests/scripts.bats` was provably never enforced locally (it only fired inside the Docker environment), and a standalone repro `.bats` file confirmed the mechanism. Any pre-existing mid-test bare-bracket assertion in the suite may therefore be silently inert: the test passes even when the asserted condition is false.

Impact: false confidence — assertions that reviewers believe are enforced are not, and regressions they were written to catch pass green.

## Scope

- Audit all `.bats` files for bare `[[ ... ]]` (and bare `(( ... ))`) statements that are not the final statement of their test body.
- Convert each to an enforced form: `[[ ... ]] || fail "..."` (bats-support `fail` is already in use) or an appropriate `assert_*` helper.
- For each converted assertion, verify it can actually fail (temporarily invert the condition) before accepting the conversion.
- Consider a lint/CI guard (e.g. a grep-based check) that rejects new bare mid-test bracket assertions.

## Open decisions

None.

## Resolution

Converted all 29 first-party standalone double-bracket assertions to explicit failure paths, calibrated every conversion against an always-false mutation, added a recursive quote/heredoc/arithmetic-aware lint checker with behavioral fixtures, and verified make test-issues, make lint, 14 affected Bats tests, and make test-ubuntu (403 cases).
