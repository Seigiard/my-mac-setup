---
title: Use validated Markdown records as the issue tracker
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0007: Use validated Markdown records as the issue tracker

## Context

Humans and several agent clients need one backlog contract that is available in
the checkout and reviewable with the code. A free-form Markdown list drifted and
could not support reliable lifecycle operations. The replacement was designed in
`docs/plans/2026-08-21-001-feat-repository-issue-management-plan.md` and introduced
in commit `cc4774a`.

## Considered options

- Move the backlog to a hosted issue tracker.
- Keep free-form Markdown and derive state with ad hoc text searches.
- Store structured Markdown records in the repository and own their schema with
  a deterministic local CLI.

## Decision

Files matching `docs/issues/YYYY-MM-DD-NNN-*.md` are the authoritative issue
corpus. `python3 scripts/issues` owns structured reads, validation, and lifecycle
mutations; Git owns history and collaboration; CI rejects invalid records. Prose
search remains available, but structured operations use the CLI.

## Consequences

Normal CLI mutations atomically replace one issue file under the worktree lock;
committed changes are then versioned by Git and work across agent clients. The
repository accepts responsibility for schema migrations and gives up hosted
primitives such as native comments, relations, notifications, and boards unless
it implements equivalents locally.
