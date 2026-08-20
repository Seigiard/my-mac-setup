---
title: FIELD_SEPARATOR pane records reached 29 positional fields across six read headers
type: follow-up
date: 2026-08-20
status: open
parent-plan: docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md
---

## Why this exists

`reconcile_presentation_pass` in `home/dot_local/bin/executable_herdr-task-sync`
passes pane state between its phases as `FIELD_SEPARATOR`-joined positional
records. The `$git_ref` work added `is_linked`, `sha`, `git_ref`, `pane_inline`,
`worktree_token`, `segment_prefix`, `current_git_ref`, and `current_pane_inline`,
taking the record widths from roughly 14/21/22/22 fields to 16/25/29/29.

Six `while IFS="$FIELD_SEPARATOR" read -r ...` headers must stay in lockstep by
position. The widest is `home/dot_local/bin/executable_herdr-task-sync:1471`,
which lists 29 variable names on one line. Two headers decode the same 29-field
row with entirely different variable names (line 1389 uses `_`-prefixed shadow
names, line 1471 uses the bare names).

Nothing detects a misalignment. A field inserted at the wrong position in only
one header silently shifts every later field in that consumer, and bash reports
no error. The failure surfaces as a wrong label, not as a crash.

This is a maintainability risk, not a current defect. The field plumbing in the
reviewed diff was verified correct: producer and consumer arities line up at
16/16, 25/25, 29/29, and 3/3 with matching positional order, and all bats tests
pass.

The codebase already has a key-based lookup idiom for exactly this shape:
`table_value_for` (added by this same change) reads a two-column
`key<FS>value` table by name.

Reported by the local maintainability reviewer and independently by the external
cross-model review leg.

## Scope

- Carry a `(pane_id, base64-encoded JSON)` pair per derived record and decode
  named fields with `jq` at each consumer, so adding a field is a one-line change
  instead of a synchronized six-site edit. The pass already base64-encodes the
  raw pane JSON at line 1130, so the idiom is established.
- Alternatively, split `reconcile_presentation_pass` (currently about 480 lines,
  1091-1571) along its existing phase boundaries into functions that each own a
  narrower record.

## Open decisions

- Whether the extra `jq` invocations are acceptable. The pass already forks one
  location probe per pane and runs several `jq` calls per publish, but a per-pane
  decode in four loops adds more. A benchmark against the current 5-second sweep
  interval should decide it.
- Whether to do this at all, or to accept the positional records and instead add
  a cheap guard: a single assertion that each record's field count matches the
  expected width before the loop consumes it. That is far smaller and catches the
  exact failure mode, without restructuring the pass.
