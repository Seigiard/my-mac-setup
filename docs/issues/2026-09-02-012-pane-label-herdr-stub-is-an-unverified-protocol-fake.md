---
title: "Pane-label herdr stub is an unverified protocol fake"
short_description: "Every pane-label and task-sync assertion in scripts_test.sh runs against the stub herdr in tests/helpers/herdr_pane_labels.bash (renamed from herdr_task_sync.bash in 21aaaf0), which reimplements herdr's envelope shapes, its jq-built snapshot skeleton, and the seq/token high-water merge semantics; nothing ever compares the fake to the real binary, and commit d080d31 shows the drift class is realized rather than theoretical."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-tests","herdr"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

The stub bakes herdr's CLI/JSON contract. It lives in
`tests/helpers/herdr_pane_labels.bash`, loaded at `tests/bashunit/scripts_test.sh:10`: the
snapshot skeleton is assembled by `jq` at `:265-267`
(`{id:"cli:api:snapshot",result:{snapshot:{protocol,panes,tabs,agents,layouts,workspaces},type:"session_snapshot"}}`),
argv and envelope handling at `:221-234` and `:253`, and the
`--seq`/`--token`/`--clear-token` high-water merge semantics at `:316-318` and `:356-359`.

`grep -rn 'command -v herdr' tests/` still returns nothing, so no test touches the real binary.
Commit `d080d31` (#115) had to change the stub's sequence comparison from `<` to `<=` because real
herdr accepts only strictly greater sequences — found by hand, not by any test. Per the
repository's upstream-ownership rule, behavior owned by an upstream system has no valid local
oracle, so more assertions against the fake would not help.

The helper this record originally named, `tests/helpers/herdr_task_sync.bash`, no longer exists:
`21aaaf0` (#73) replaced it with `tests/helpers/herdr_pane_labels.bash`, so the previously cited
line numbers (`:379`, `:434-464`, `:248`, `:680`) point at unrelated code and the "task-sync"
naming is dead. The gap it describes is unchanged.

## Scope

Record the herdr version and protocol number the stub emulates beside the fixture, and add a
host-only, skip-if-absent check that runs the real `herdr api snapshot` and compares its top-level
result keys against the stub's. Do not reimplement herdr semantics locally to make them testable.

## Open decisions

Whether a real-herdr conformance check belongs in the post-apply suite (where herdr is present on a
dev host but absent in CI-minimal Linux) or in a separate host-only target.
