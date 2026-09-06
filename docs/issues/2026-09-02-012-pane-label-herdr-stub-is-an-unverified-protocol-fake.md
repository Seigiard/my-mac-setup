---
title: "Pane-label herdr stub is an unverified protocol fake"
short_description: "Every pane-label and task-sync assertion in scripts_test.sh runs against the stub herdr in tests/helpers/herdr_pane_labels.bash (renamed from herdr_task_sync.bash in 21aaaf0), which reimplements herdr's envelope shapes, its jq-built snapshot skeleton, and the seq/token high-water merge semantics; nothing ever compares the fake to the real binary, and commit d080d31 shows the drift class is realized rather than theoretical."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-tests","herdr"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-05"
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

## Resolution

The stub's emulated herdr version and protocol are now recorded beside the fixture in tests/helpers/herdr_pane_labels.bash as herdr 0.8.2 / protocol 20, both read from the installed binary rather than assumed (herdr --version, and herdr api snapshot | jq .result.snapshot.protocol). The fixture's two literals said protocol 19; they are corrected to 20. That correction is inert for behaviour: grep confirms executable_herdr-pane-labels never reads .protocol and no test asserted 19, the literal only ever recorded what the fake claims to be. scripts_test.sh test 1209 adds the conformance check using the existing skip-if-absent idiom from palette_test.sh:1313, so the open decision is settled by precedent rather than a new Makefile target. It captures the real snapshot before hpl_setup repoints HERDR_SOCKET_PATH, then compares jq -S -c '.result | keys' from the real binary against the stub's. The oracle is the binary itself, not anything in this patch. Verified on macOS: the check runs rather than skips here, passing with 4 assertions; adding a spurious top-level result key to the stub turns it red with expected ["snapshot","type"] against actual ["cursor","snapshot","type"], the expected side visibly coming from upstream; restoring returns it to green. A second skip path covers herdr being present with no running server, carrying the binary's own error text, because without a server there is no oracle. The comparison was deliberately kept to top-level result keys: a deeper check would pin a shape only herdr owns. Real herdr 0.8.2 and the stub agree at that level, both returning ["snapshot","type"]. One level down they diverge, the stub omitting focused_pane_id, focused_tab_id, focused_workspace_id and version, which the engine reads none of today; that is recorded as 2026-09-05-007 rather than encoded here. make lint (exit 0), tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh (343 passed, 1 pre-existing platform skip, 344 total, 1798 assertions), and make test-issues (58 tests OK) all pass. Only test files changed, so this is checkout-logic risk class and make test-local does not apply.
