---
title: "Two suites assert Markdown prose instead of behavior"
short_description: "scripts_test.sh test 058 and smoke_test.sh test 60 spend 32 assertions matching English sentences in child-agent-contract.md and three SKILL.md files; they execute nothing, redden on any copy-edit, and stay green through the lifecycle regressions they name."
type: "bug"
category: "testing-ci"
tags: ["tautological-tests","test-quality","documentation"]
date: "2026-08-29"
status: "in-progress"
priority: "medium"
---

## Why this exists

The same mistake appears independently in two suites: a test whose entire assertion set
matches English sentences in a Markdown document. Nothing parses these documents at
runtime, so the assertions cannot detect a regression in the behavior they describe, and
any rewording of the prose reddens the suite.

- `tests/bashunit/scripts_test.sh:1856-1871` (test 058, "source contracts document
  lifecycle boundaries") — 16 `assert_file_contains` calls against
  `home/private_dot_claude/skills/.../child-agent-contract.md`, `herdr/SKILL.md` and
  `ask-in-herdr/SKILL.md`. The test executes no script.
- `tests/bashunit/smoke_test.sh:943-958` (test 60, "deployed herdr child contracts") — 16
  loose regexes over two deployed prose docs. The patterns are weak enough to match
  unrelated text: `generation.*event` matches 5 lines that have nothing to do with the
  contract.

Both tests name real lifecycle properties. Every one of those properties is either already
covered behaviorally elsewhere or is cheaply coverable.

## Scope

For `scripts_test.sh` test 058, the claimed properties already have behavioral owners:
`herdr-child start --wait` vs `--detach` exit shape is covered by tests 023 and 064; the
`prompt … --detach` rearm-to-reap sequence in `calls.log` is covered by tests 053 and 092;
the nonzero-recovery-JSON contract can be asserted with `run child_start …;
assert_failure; run jq -e '.supervision.status'`. Delete the prose assertions.

If the intent is genuinely "the documentation stays in sync with the CLI", assert the
derived property instead: extract every `herdr-child <sub>` token from the Markdown and
assert each is an accepted subcommand of the real script.

For `smoke_test.sh` test 60, drop the 16 regexes and retain the two facts that can regress
silently. `~/.claude/skills/herdr/SKILL.md` is currently covered only by this test — add it
to test 21's deployment manifest. If the documented markers are a real wire format, assert
that `herdr-child` emits a marker the documented shape matches, rather than asserting the
sentence describing it.

Run `make test-suite`, then `make test-ubuntu`.

## Open decisions

Whether the child-supervision markers documented in `child-agent-contract.md` are a
consumed wire format or explanatory prose. If they are consumed, a round-trip test between
emitter and documented shape replaces both tests; if not, the assertions should simply go.
