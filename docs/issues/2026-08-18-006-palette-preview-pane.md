---
title: Show a preview of the selected pane's contents in the command palette
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). It has no preview of any kind. On a wide
terminal the right-hand column shows keybinding hints scraped from Ghostty/kitty config comments
(`load_key_binding_groups`, `palette.py:546-587`) — static text, unrelated to what is selected.

That is a real gap for anything that acts on a pane. A `pane_run` command sends a shell line to the
pane that opened the palette; a workspace picker jumps somewhere. In both cases the user is choosing
blind, and the palette already knows enough to show them.

herdr 0.8.0 exposes exactly the primitive needed, verified against the installed binary:

```
herdr pane read --help
  --source <SOURCE>   [possible values: visible, recent, recent-unwrapped, detection]
  --lines <N>
  --format <FORMAT>   [possible values: text, ansi]
```

## Scope

Render the selected row's target pane in a preview region, driven by `pane.read`.

Two cost controls are mandatory, both proven in `jeffarese/herdr-bar`:

- **Debounce on selection change** (~70 ms) so holding an arrow key does not fire one read per row.
- **A short TTL cache** (~1.5 s) so returning to a row does not re-read it.

`app.py:610-635` in that repo carries both. The same repo also demonstrates the more general pattern
worth adopting: a work queue that performs **at most one expensive reading per event-loop pass**
(`app.py:658-670`), so input never waits on I/O.

`mr04vv/herdr-pane-navigator` is the cautionary counter-example — it runs one `pane read` per pane in
the previewed tab on every cursor move with no cache and no debounce, and its own dossier flags that
as the weakest part of the design.

`--format ansi` preserves the pane's own colors, which is what makes a preview readable at a glance.

## Scope boundary

This issue covers preview for panes. Previewing what a `shell` command *would* do is a different and
much harder problem, and is out of scope.

## Open decisions

- Whether preview is on by default or behind a toggle key. herdr-bar uses `ctrl+o`.
- What to preview for command types with no pane target — nothing, the command body, or the
  resolved command after placeholder expansion.
- Whether the preview replaces the keybinding-hints column or gets its own region. The palette
  currently only shows that column when the terminal is at least 99 columns wide.
- Whether reading a pane can disturb it. An open bug in `dmnkf/herdr-omnisearch` reports its indexer
  scrolling the user's panes while harvesting output, so this needs checking before shipping.
