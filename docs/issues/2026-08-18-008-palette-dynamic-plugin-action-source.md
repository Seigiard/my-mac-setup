---
title: "Surface every installed herdr plugin's actions in the command palette"
short_description: "Surface every installed herdr plugin's actions in the command palette"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Every command it shows must be written by
hand into `~/.config/herdr/command-palette/commands.toml` or a sibling `*.toml`. There is no
dynamic source of any kind — the command list is exactly what is declared.

That means another plugin's actions are invisible unless someone remembers to transcribe them.
This repo already has a second plugin with actions (`seigi.pane-labels`, whose `sweep` action is
declared in `home/private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml`) and it does
not appear in the palette.

`herdr plugin action list` returns every installed plugin's actions in one call.

## Scope

Add a dynamic source that reads plugin actions and renders them as palette rows alongside the
declared commands, filtering out the palette's own actions so it cannot invoke itself.

`JanTvrdik/herdr-command-palette` is the reference and it is roughly ten lines
(`palette.sh:26-36`). Its whole command list is this one call — the opposite pole from our static
TOML, which is why the two designs are worth combining rather than choosing between.

An alternative read path exists: `speardragon/herdr-command-center` reads herdr's merged plugin
registry at `~/.config/herdr/plugins.json` directly (`src/plugin-actions.mjs:14-20`), which avoids a
subprocess and surfaces actions nobody bound to a key. Worth measuring against the CLI call.

Rows from this source need a distinct origin label. The palette already renders `Project · <group>`
and `Global · <group>` headings when more than one origin is present
(`display_group_label`, `palette.py:394-395`), so a third origin fits the existing mechanism.

## Related

An action dispatched with `herdr plugin action invoke` is fire-and-forget — a zero exit code means
only "accepted". Verifying that a dispatched action actually reached a terminal state is filed
separately; it matters more once the palette can dispatch actions it did not author.

## Open decisions

- Whether dynamic rows are always shown or opt-in per plugin, given that a noisy plugin could
  swamp the hand-curated list.
- Whether to cache the action list. It changes only when a plugin is installed or enabled, so a
  `[[events]]`-driven refresh or a simple TTL both work; re-reading on every open is the current
  palette's habit and the thing worth not repeating.
- How a dynamic row participates in frecency and aliases, given it has no stable line in a TOML file
  to hang state off — the plugin id plus action id is the natural key.
