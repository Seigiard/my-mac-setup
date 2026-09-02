---
title: "Decompose herdr-child lifecycle engine"
short_description: "The 2,468-line shell executable combines launch, watcher, callback, continuation, and reap state machines in one file; split it behind the existing semantic suite without changing lifecycle behavior."
type: "chore"
category: "herdr"
tags: ["maintainability","herdr-child"]
date: "2026-08-26"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

`home/dot_local/bin/executable_herdr-child` has grown to 2,468 lines. It contains argument parsing, launch cleanup, watcher delivery, callback receipts, continuation handoff, reap recovery, metadata serialization, and owner-lock handling in one shell executable.

The current implementation is covered by semantic lifecycle tests and passed the disposable Ubuntu suite. Splitting it during the supervision change would increase regression risk without changing user behavior, but leaving every state machine in one file makes future race fixes harder to review and isolate.

## Scope

- Identify boundaries that preserve one deployed `herdr-child` entrypoint and Bash 3.2 compatibility.
- Extract cohesive lifecycle modules without changing command output, exit codes, metadata, or recovery semantics.
- Keep test-only barriers explicit and unavailable as user-facing command options.
- Run the existing Herdr child semantic suite red/green for each extraction, then run `make test-ubuntu`.

## Open decisions

None. The refactor keeps one entrypoint backed by sourced Bash modules. Broader
state-machine and JSON-predicate simplification is deferred to
`2026-08-30-010-research-simplifying-herdr-child-lifecycle`.

## Resolution

Split the 2,468-line herdr-child executable into six Bash 3.2 sourced lifecycle
modules while preserving one 49-line deployed entrypoint and semantic behavior.
Added source-order, function ownership/redefinition, source-time purity, reap
recovery, live watcher argv, and deployed source-resolution coverage. Verified
the 83-test `herdr_child` owner (436 assertions), descriptor probe, `make lint`,
`make test-issues` (44 tests), and `make test-ubuntu` with exit status 0.
`make test-local` did not produce a verdict after 8 minutes 45 seconds and is
tracked separately as
`2026-08-30-006-make-test-local-stalls-in-host-diff`; it is not counted as
verification evidence. The implementation plan now treats that host-only diff
as supplementary because `make test-ubuntu` owns disposable checkout apply and
deployment verification.
