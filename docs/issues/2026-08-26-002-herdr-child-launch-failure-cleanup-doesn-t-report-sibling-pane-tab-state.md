---
title: "herdr-child: launch-failure cleanup doesn't report sibling-pane tab state"
short_description: "47ef76d consolidated the four named cleanup helpers into one cleanup_pane (home/dot_local/lib/herdr-child-launch.sh:166-192) reached from ~18 launch-failure sites; it still ends at herdr pane close and never calls tab_reap_status, so unlike herdr-child reap (herdr-child-reap.sh:158-164, 'kept with N panes') a parent agent watching a launch failure learns nothing about the tab's fate — deliberately unbranched per the tab-mode plan's KTD3/KTD4 decision, and now a one-site change rather than four."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","tab-mode","observability","code-review-residual"]
date: "2026-08-26"
status: "open"
priority: "low"
---

## Why this exists

`docs/plans/2026-08-26-1123-feat-herdr-child-tab-mode-plan.md` added a `--tab`
launch mode to `herdr-child start`. The four cleanup helpers this record
originally named — `close_unregistered_pane`, `close_collision_pane`,
`close_registered_pane`, and `signal_cleanup` — no longer exist. `47ef76d`
(split child lifecycle into modules) consolidated them into one `cleanup_pane`
(`home/dot_local/lib/herdr-child-launch.sh:166-192`), reached from roughly
eighteen launch-failure sites (`:210`, `:271`, `:329`, `:345`, `:352-458`,
`:531`) plus `owned_launch_signal`. The implementation moved out of
`home/dot_local/bin/executable_herdr-child`, which is now a dispatcher.

The observability gap is unchanged. `cleanup_pane` ends at
`herdr pane close "$pane"` and never calls `tab_reap_status`
(`herdr-child-runtime.sh:446`) or `herdr tab get`. The session-settled
rationale (KTD3/KTD4 in the plan) still holds: herdr's own last-pane-close
auto-close, measured in the plan's U1 against herdr 0.8.2, makes a plain pane
close correct regardless of mode — closing the child's pane either takes the
whole tab with it or leaves the tab open with its sibling, and herdr decides.

What a parent agent loses is the signal about which of those happened. `reap`
reports all three outcomes (`herdr-child-reap.sh:158-164`): `closed pane %s`,
`closed pane %s; tab %s kept with %s panes`, and `closed pane %s and tab %s`.
`cleanup_pane` reports nothing on success and only `preserving pane ...` on
refusal.

This was deliberately not changed during the tab-mode work: no launch-failure
path realistically produces a sibling pane in a tab the script created moments
earlier for one child, so the reporting is believed to be dead weight — but it
is a genuine gap if that assumption is ever wrong (for example a future feature
that adds a sibling pane before the child's launch settles). Two independent
peer sessions via `se-code-review` flagged it.

This is not a duplicate of `2026-08-18-021`, which concerns authorization
rather than reporting.

## Scope

Decide whether `cleanup_pane` should query tab state after a successful
`pane close` (via `tab_reap_status`, the helper `reap` already uses) and report
the outcome the way `reap` does. Because the four helpers are now one, the
change is a single site rather than four. If the no-sibling assumption is
confirmed durable, close this as `wontfix` with that reasoning recorded
instead.

Out of scope: changing the close mechanism itself — this is purely about
surfacing which outcome occurred.

## Open decisions

- Is there any current or planned herdr-child path that could add a sibling
  pane to a child's tab before that child's launch-failure cleanup runs? If
  genuinely never, `wontfix` beats implementing.
- If implemented, should the messages reuse `reap`'s exact wording for
  consistency, or stay distinct given the different call sites?
