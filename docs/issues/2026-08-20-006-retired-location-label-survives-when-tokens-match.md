---
title: "Retired location_label survives on a pane whenever every compared token already matches"
short_description: "Retired location_label survives on a pane whenever every compared token already matches"
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-20"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md"
closed: "2026-08-20"
---

## Why this exists

`location_label` is the retired predecessor of the `git_ref` pane token. The
comment at `home/dot_local/bin/executable_herdr-task-sync:1528-1530` states the
intent: "every write path clears it so panes labeled by the old deployed version
shed the legacy token instead of carrying it forever". Both publish arms do pass
`--clear-token location_label` (lines 1534 and 1538).

The gap is that a write is not guaranteed to happen. The snapshot query that
builds `pane_rows` (`home/dot_local/bin/executable_herdr-task-sync:1123-1131`)
reads these tokens and no others:

```
(.tokens.task // ""), (.tokens.repo // ""), (.tokens.worktree // ""),
(.tokens.branch // ""), (.tokens.location_status // ""),
(.tokens.git_ref // ""), (.tokens.pane_inline // "")
```

`location_label` is absent. The `location_changed` computation at lines 1486-1500
therefore never inspects it. When every compared token already equals its
intended value, `location_changed` stays 0, no metadata write is issued, and the
stale `location_label` is never cleared.

The reachable window is the rollout skew the plan's own U6 already names:
replacing `~/.local/bin/herdr-task-sync` does not restart a running
`--sweep-daemon`, so an old-version daemon keeps writing `repo`, `worktree`,
`branch`, `location_status`, and `location_label`. The old daemon knows nothing
about `git_ref` or `pane_inline`, so it neither writes nor clears them and the
new values survive. The next new-version pass then finds every compared token
matching, writes nothing, and the pane keeps the legacy `location_label`
indefinitely, until its git location actually changes.

Impact is limited to agents and tools that read pane tokens directly: they see
stale folder-first location context after the sidebar has moved to `$git_ref`.
The sidebar itself is unaffected, because `config.toml` no longer references
`$location_label`.

This was found only by the external cross-model review leg. Two local reviewers
(adversarial, api-contract) explicitly cleared the retirement path; both checked
that the write paths clear the token, and neither checked that a write is
guaranteed to fire. The mechanism above was verified directly against the jq
token list.

## Scope

- Read `.tokens.location_label` into `pane_rows` alongside the other current
  tokens, thread it through the pane records as `current_location_label`, and set
  `location_changed=1` when it is non-empty. That makes the clear self-healing on
  the next pass regardless of what else matches.
- Add a bats case: a pane whose new tokens all match its intended values but that
  still carries `location_label`, asserting the pass issues a metadata write with
  `--clear-token location_label`.

## Open decisions

- Whether to fix this at all, or to close it as accepted and rely on the plan's
  U6 instruction to restart the sweep daemon on rollout. The token is invisible
  in the sidebar, so the cost of leaving it is bounded.
- If fixed: whether to keep the extra `location_label` column permanently, or to
  gate it behind a one-release cleanup and then remove the column so the pane
  record does not grow further. The record is already 29 positional fields wide
  (see the field-bus issue filed alongside this one).

## Resolution

Fixed in commit 9e69d0b, by a different mechanism than the scoped one: instead
of widening the 29-field pane record with a `current_location_label` column, the
pass names the panes still carrying `location_label` in a separate jq read off
the snapshot (`legacy_label_panes`) and forces `location_changed=1` for them via
`list_contains_line`. The publish arms already clear the token; the fix only
guarantees a write fires. This resolves the second open decision in favor of not
growing the positional record. The mirrored final-payload re-check also inspects
`location_label`, so a transient pass keeps retaining. Covered by the bats case
"location clears a retired location_label even when every published token
already matches", which replays the stale-daemon rollout skew directly.
