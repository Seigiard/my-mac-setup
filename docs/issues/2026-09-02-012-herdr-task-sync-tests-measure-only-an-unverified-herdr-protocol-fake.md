---
title: "herdr-task-sync tests measure only an unverified herdr protocol fake"
short_description: "Every task-sync assertion in scripts_test.sh runs against the stub herdr in tests/helpers/herdr_task_sync.bash, which reimplements herdr's envelope shapes, snapshot skeleton, and report-metadata sequence semantics; nothing ever compares the fake to the real binary, and commit d080d31 shows the drift class is realized rather than theoretical."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-tests","herdr"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

The stub bakes herdr's CLI/JSON contract: envelope shapes at tests/helpers/herdr_task_sync.bash:379, the snapshot skeleton at :434-464, and the --seq/--token/--clear-token high-water merge semantics at :248 and :680. grep -rn 'command -v herdr' tests/ returns nothing, so no test touches the real binary. Commit d080d31 (#115) had to change the stub's sequence comparison from < to <= because real herdr accepts only strictly greater sequences -- found by hand, not by any test (docs/issues/2026-08-30-003). Per the repository's upstream-ownership rule, behavior owned by an upstream system has no valid local oracle, so more assertions against the fake would not help.

## Scope

Record the herdr version and protocol number the stub emulates beside the fixture, and add a host-only, skip-if-absent check that runs the real 'herdr api snapshot' and compares its top-level result keys against the stub's. Do not reimplement herdr semantics locally to make them testable.

## Open decisions

Whether a real-herdr conformance check belongs in the post-apply suite (where herdr is present on a dev host but absent in CI-minimal Linux) or in a separate host-only target.
