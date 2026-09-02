---
title: "herdr-child: launch-failure cleanup doesn't report sibling-pane tab state"
short_description: "close_unregistered_pane, close_collision_pane, close_registered_pane, and signal_cleanup all close only the child's own pane and never query or report whether a --tab child's tab held sibling panes (unlike herdr-child reap, which reports 'kept with N panes'); deliberately left unbranched per the herdr-child-tab-mode plan's session-settled KTD3/KTD4 decision (herdr's own last-pane-close auto-close makes a plain pane close correct regardless of siblings), and no launch-failure code path realistically produces a sibling pane in a tab the script just created, but code review flagged the observability gap for a parent agent watching these paths."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","tab-mode","observability","code-review-residual"]
date: "2026-08-26"
status: "open"
priority: "low"
---

## Why this exists

`docs/plans/2026-08-26-1123-feat-herdr-child-tab-mode-plan.md` added a `--tab` launch mode to `herdr-child start` (implemented in `home/dot_local/bin/executable_herdr-child`). Four launch-failure cleanup helpers — `close_unregistered_pane`, `close_collision_pane`, `close_registered_pane`, and `signal_cleanup` — all close only the child's own pane (`herdr pane close "$pane"`), unchanged from pane mode, and never call `herdr tab get` the way `reap_children` does. Their session-settled rationale (KTD3/KTD4 in the plan) is that herdr's own last-pane-close auto-close, measured in the plan's U1 against herdr 0.8.2, makes this correct regardless of mode: closing the child's pane either takes the whole tab with it (no siblings) or leaves the tab open with the sibling (siblings present) — herdr decides, not this script.

Code review (two independent peer sessions via `se-code-review`) flagged that this means a parent agent watching one of these failure paths gets no signal about which outcome happened — `reap` reports "closed pane and its tab X" vs. "tab X kept with N panes" (see `reap_children` in the same file), but the four launch-cleanup helpers report nothing beyond their existing "preserving pane" failure messages, silent on success either way.

This was deliberately not changed during the tab-mode work: no launch-failure code path realistically produces a sibling pane in a tab the script just created moments earlier for this one child, so the reporting gap is believed to be dead weight in practice — but it is a genuine observability gap if that assumption is ever wrong (e.g. a future feature that adds a sibling pane to a child's tab before the child's own launch settles).

## Scope

Decide whether the four launch-cleanup helpers should query tab state (via `herdr tab get`, matching `reap_children`'s existing pattern) after a successful `pane close`, and report the outcome the way `reap` does. If yes, thread that reporting through all four call sites consistently. If the assumption that no sibling can exist at launch-cleanup time is confirmed durable, this issue can close as `wontfix` with that reasoning recorded instead.

Out of scope: changing the close *mechanism* itself (already correct and tested) — this is purely about surfacing which outcome occurred.

## Open decisions

- Is there any current or planned herdr-child code path that could add a sibling pane to a child's tab before that child's own launch-failure cleanup runs? If genuinely never, this may be better closed as `wontfix` than implemented.
- If implemented, should the messages match `reap_children`'s exact wording ("closed pane %s and its tab %s" / "closed pane %s; tab %s kept with %s panes") for consistency, or stay distinct given the different call sites?
