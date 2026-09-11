---
title: Retain bashunit with a Bats-compatible vocabulary
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0011: Retain bashunit with a Bats-compatible vocabulary

## Context

The post-apply shell suite needed lower wall-clock time without changing its
behavior. The experiment preserved all 403 test results and improved wall-clock
time by 24.1% on macOS and 24.4% in Docker, but it missed the plan's exploratory
30% threshold. The evidence is recorded in
`docs/benchmarks/bashunit-full-suite-experiment.md`.

## Considered options

- Keep Bats as the production runner.
- Rewrite the suites to native bashunit semantics.
- Run on bashunit while permanently preserving the suite's Bats-compatible
  capture and assertion vocabulary.

## Decision

The production suite uses the pinned bashunit runner with the permanent
compatibility DSL in `tests/bashunit/test-dsl.bash`. The committed bashunit suites
and compatibility DSL are authoritative; selected Bats-derived semantics and
vocabulary remain without retaining Bats itself. The 30% figure was an experiment
target, not a binding decision gate: exact 403/403 parity and stable improvement
of about 24% on both platforms were sufficient to adopt the migration.

## Consequences

The suite is faster without a mass test rewrite, but the repository permanently
owns the compatibility layer and its Bash 3.2 quirks. Converted suites keep
special shellcheck handling, and future runner changes must preserve semantic
parity rather than only producing a green aggregate result.
