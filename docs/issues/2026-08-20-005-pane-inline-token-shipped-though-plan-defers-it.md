---
title: "pane_inline token is published on every pane although the plan defers it and nothing consumes it"
short_description: "pane_inline token is published on every pane although the plan defers it and nothing consumes it"
type: "follow-up"
category: "repository-maintenance"
tags: ["repository-maintenance","follow-up"]
date: "2026-08-20"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md"
closed: "2026-08-20"
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

## Resolution

Direction A — removed, following the plan. Commit
4b93f82f8d3cc302f3b09ab125eb6ebec6ab32f7.

In `home/dot_local/bin/executable_herdr-task-sync`:

- Deleted `pane_inline_label_for`.
- Dropped `pane_inline` from the pane_rows jq token list and removed the
  `pane_inline` / `current_pane_inline` / `_pane_inline` / `final_pane_inline`
  slots from all positional `FIELD_SEPARATOR` records and every matching
  `read -r` header; producers and consumers re-verified in lockstep
  (pane_rows 15 fields, pane_intents 24, pane_presentations 27, final_tokens 6).
- Deleted both pane_inline change-detection arms; the guarded block now only
  covers the legacy `location_label` shed.

On the sub-decision: kept one `--clear-token pane_inline` on both
location-publish arms (single flag, cheap; sheds the stale token from panes
labelled by the previous version whenever a location write fires). It can be
dropped in a later release once no deployed version writes the token — same
retirement path as `location_label`.

Tests: the three `pane_inline` assertions in `tests/scripts.bats` now assert
the token is absent, and the transient-identity test pre-seeds a stale
`pane_inline` token to prove a location write clears it. Verified:
`make lint` clean; `bats tests/scripts.bats` 187/189 (the two reds are
pre-existing on unmodified main: the 1000ms coordinator-concurrency timing
flake on this machine, and the Pi terminal-theme red tracked by
`2026-08-20-003-pi-terminal-theme-hex-vars-red-test.md`);
`bats tests/smoke.bats` 106/107 (the one red is the known
`coding agents use terminal color palettes` leftover-file failure tracked
separately). All published labels other than the removed token are unchanged.
