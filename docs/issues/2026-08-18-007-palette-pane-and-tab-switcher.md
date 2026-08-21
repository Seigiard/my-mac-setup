---
title: "Add a pane switcher and a tab switcher to the command palette"
short_description: "Build searchable pane and tab rows from `session.snapshot`, using the socket-only `pane.focus` method because the CLI cannot focus arbitrary non-agent panes by ID."
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). It can switch workspaces and nothing else.

The existing `workspace_picker` command type (`pick_workspace`, `palette.py:954-977`) shells out to
`herdr workspace list`, draws its own curses list of number / label / tab count / pane count /
agent status, and focuses the choice. It has **no search box** — arrow keys only — and there is no
pane switcher and no tab switcher at any level.

With eight tabs and nine panes on this machine, most of them agent sessions, "jump to the pane where
that agent is blocked" is a thing the palette cannot do at all.

## Scope

Two new command types, `pane_picker` and `tab_picker`, plus a fuzzy input on the existing workspace
picker.

The blocking detail is **how to focus a pane**, and `mr04vv/herdr-pane-navigator` documents it
(`pane-navigator.sh:401-417`): the CLI cannot do it. `herdr pane focus` only moves to a *neighbouring*
pane and takes a direction rather than an id, and `herdr agent focus` rejects panes with no detected
agent — which excludes plain shells. The socket method `pane.focus` accepts a pane id outright.
It is present in `herdr api schema --json` on 0.8.0.

That makes this issue depend on the socket client (see the separate issue on replacing
subprocess-per-call transport), or on a minimal single-purpose socket call if that lands later.

Row content worth copying from the same repo:

- Sort by urgency, with a parent inheriting its most urgent descendant's urgency, so a workspace
  containing a blocked agent floats to the top (`:86-97`).
- For a blocked agent, show **the actual question it is waiting on**, scraped from its screen
  (`blocked_reason`, `:427-462`).
- Borrow a tab's title from an agent pane inside it when the tab label is just a number (`:126-138`).

`session.snapshot` already returns panes with `label`, `agent`, `agent_status`, `tab_id` and
`workspace_id` in one call, so building the rows needs no extra round trips.

## Open decisions

- Whether these are separate command types or one unified tree of workspace → tab → pane, which is
  what pane-navigator does. A tree is better UX and a larger change.
- Whether the currently focused pane sorts last (pane-navigator does this deliberately, so Enter
  always takes you elsewhere) or first.
- Whether to support acting on a pane from the list — answering a blocked agent with `y`/`n` without
  focusing away is pane-navigator's most useful feature and its largest scope increase.
