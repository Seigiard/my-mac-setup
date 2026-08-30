---
title: "Decompose herdr-child lifecycle engine"
short_description: "The 2,468-line shell executable combines launch, watcher, callback, continuation, and reap state machines in one file; split it behind the existing semantic suite without changing lifecycle behavior."
type: "chore"
category: "herdr"
tags: ["maintainability","herdr-child"]
date: "2026-08-26"
status: "open"
priority: "medium"
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

- Whether launch, watcher, and metadata helpers should be sourced modules or generated into one deployed executable.
- Whether the current Python JSON predicates should be consolidated in the same change or in a separate measured optimization.
