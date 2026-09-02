---
title: "test-oracle-guard misses positive tautological tests"
short_description: "The shared guard engine denies only negative-assertion patterns, so the 2026-09-02 ghostty-shortcuts incident's positive tests with expected values from the same patch passed all three client hooks silently; extending it needs a low-false-positive signal such as requiring an oracle: comment on new test functions."
type: "follow-up"
category: "testing-ci"
tags: ["test-oracle","hooks"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

The shared engine `home/dot_local/bin/executable_test-oracle-guard` fires only on negative-assertion patterns (`assert_not_contains`, `refute_match`, `! grep`, ...). In the 2026-09-02 ghostty-workspace-shortcuts session, an agent added two positive tests to `tests/bashunit/palette_test.sh` whose expected values (new command-kind names) came from the same patch that introduced them — the textbook tautology the CLAUDE.md gate forbids — and all three client hooks (Claude Code, OpenCode, Pi) stayed silent because no negative pattern was present. Prose alone did not stop it; the enforcement layer has a structural blind spot.

## Scope

Extend the engine with a low-false-positive signal for positive tautologies, or explicitly decide the class stays prose-only. Candidate mechanism: require an `oracle:` comment within N lines above every *new* test function in a proposed edit (the existing escape-hatch convention, applied at function granularity instead of only on flagged negative lines). Weigh blast radius per `docs/solutions/design-patterns/gate-bias-follows-blast-radius.md` — this would touch every new test in every repo across all three clients. Update the three thin adapters only if the engine's stdin/argv contract changes.

## Open decisions

Whether requiring `oracle:` on every new test function is acceptable friction, or whether the requirement should apply only to test files touched in the same session as non-test files (needs session state the stateless hook does not have today).
