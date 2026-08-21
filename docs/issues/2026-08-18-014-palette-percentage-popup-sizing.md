---
title: "Size the command palette popup in percentages instead of fixed cells"
short_description: "Size the command palette popup in percentages instead of fixed cells"
type: "chore"
category: "command-palette"
tags: ["command-palette","chore"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its opener hardcodes the popup size in
absolute terminal cells (`open.py:186-192`):

```python
"--placement", "popup",
"--width", "104",
"--height", "34",
```

104×34 is a compromise that fits nothing well. On a 300-column monitor the palette is a small box in
a sea of empty space; on a laptop it is most of the screen. The number is also load-bearing for a
defect filed separately — the main list truncates to `rows - 10` commands with no scrolling, so the
hardcoded 34 directly sets the ceiling on how many commands are reachable.

herdr manifests support percentage sizing. `meerzulee/herdr-float` declares
`width = "86%"` / `height = "82%"` in its manifest and never computes geometry at all; centering is
herdr's job. `jeffarese/herdr-bar` uses `74%` / `62%` and its README states the principle plainly:
"popup size lives in herdr, not here."

## Scope

Move the size into `herdr-plugin.toml` as percentages and drop the flags from `open.py`.

There is a discrepancy to resolve while touching this. The manifest declares
`placement = "overlay"` for the `palette` pane (`herdr-plugin.toml:20-24`), while `open.py` passes
`--placement popup`, so the manifest's declared placement is overridden at open time. Which one is
actually in effect matters beyond tidiness: `mr04vv/herdr-pane-navigator` reports that an overlay
pane zooms the tab it covers and that herdr kills the overlay's whole process group on close, which
is the mechanism behind the palette's `sleep`-based focus workarounds. `haphamdev/herdr-simple-switcher`
declares all its panes `popup`, focuses directly, and has no workaround at all.

## Caution, measured

On herdr 0.8.0, `herdr plugin pane open --help` lists only `overlay, split, tab, zoomed` as
placements and documents **no** `--width` / `--height` flags. Invoking it with
`--placement popup --width 104 --height 34` still returns `{"result":{"type":"ok"}}`. The palette
demonstrably works today, so `popup` is alive — but it has fallen out of the CLI help, which is a
silent-drift risk on the next herdr upgrade. Confirm what the manifest percentages actually do
before deleting the flags.

## Open decisions

- Which percentages. The keybinding-hints column only renders at 99+ columns
  (`render_curses_palette`, `palette.py:713-720`), so the width must not drop the palette below that
  on a normal laptop.
- Whether to keep a floor in absolute cells for very small terminals.
- Whether `placement` should be `popup` or `overlay`, decided on evidence rather than inherited.
