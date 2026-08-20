---
title: pane_inline token is published on every pane although the plan defers it and nothing consumes it
type: follow-up
date: 2026-08-20
status: open
parent-plan: docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md
---

## Why this exists

`docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md` lists custom
`$pane_inline` under **Deferred by design** (line 196-197), and its resolved
decision 3 says to keep herdr's native `pane` row and "revisit only if
dimming/spacing control is needed".

The shipped code implements it anyway. `home/dot_local/bin/executable_herdr-task-sync`:

- `pane_inline_label_for` formats the token (around line 936).
- The token is threaded through all four `FIELD_SEPARATOR` pane records
  (lines 1130, 1145, 1216, 1295, 1350).
- It drives its own change-detection arm at line 1489 and the mirrored
  re-check around line 1513.
- It is published on every location write: `--token "pane_inline=$pane_inline"`
  at lines 1534 and 1538.

Nothing renders it. `home/private_dot_config/herdr/config.toml:57` is the only
sidebar row definition and reads:

```toml
rows = [["state_icon", "workspace", "pane"], ["$git_ref"]]
```

A repo-wide grep finds no `$pane_inline` reference in any TOML file.

Consequence: every pane label rename now also triggers a `herdr pane
report-metadata` write under `LOCATION_SOURCE_ID` to keep a token in sync that
no surface reads.

Found independently by three reviewers (correctness, maintainability,
api-contract) and confirmed by a validation pass.

One contributing reviewer additionally claimed the comment above line 1489
contradicts the code. That sub-claim is wrong and is recorded here so it is not
re-investigated: the comment describes the *guard* on the pane_inline check, and
the guard at 1487-1489 does correctly exclude the "transient pass with no
evidence" case.

## Scope

Pick one of the two directions below, then make the code and the plan agree.

Direction A, follow the plan (remove it):

- Delete `pane_inline_label_for`.
- Drop `pane_inline` / `current_pane_inline` / `_pane_inline` / `final_pane_inline`
  from the jq token list at line 1130 and from all four positional records and
  their `read -r` headers.
- Delete the change-detection arms at 1489 and around 1513.
- Replace `--token "pane_inline=..."` with `--clear-token pane_inline` for one
  release so already-labelled panes shed the token, then drop that too.
- Update the three bats tests that assert `pane_inline` in `.tokens`.

Direction B, keep it:

- Amend the plan's Deferred-by-design list and decision 3.
- Add a `config.toml` row that actually renders `$pane_inline`, so the token has
  a consumer.

## Open decisions

- Which direction. The plan is the committed contract, which argues for A; but
  the token is already written and tested, which makes B cheaper today.
- If A: whether the one-release `--clear-token pane_inline` window is worth the
  code, given that a pane's location eventually changes anyway and the token is
  invisible either way.
