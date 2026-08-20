---
title: "opencode resolves bare-int theme values through a hardcoded standard-16 table, not the live terminal palette"
type: follow-up
date: 2026-08-20
status: open
---

## Why this exists

Discovered while building the terminal-theme-playground (during KTD5
verification against sst/opencode @ `ad192a59b5517fb432bc5f4d27f131d605a22beb`):

- In `packages/tui/src/theme/index.ts`, `resolveColor` routes a bare integer
  in a custom theme JSON through `ansiToRgba(code)` — a **hardcoded** standard
  table (`0 #000000, 1 #800000, … 7 #c0c0c0, 8 #808080, …`). It never queries
  the terminal's live palette.
- Only the built-in `system` theme queries the live palette
  (`renderer.getPalette({size: 16})` in `packages/tui/src/context/theme.tsx`),
  and even it computes muted text, borders, panel backgrounds, and diff
  backgrounds from background luminance rather than palette slots.
- opencode's TS `ColorValue` type does not even include `number`; the bare-int
  pathway is undocumented runtime behavior.

Consequence for this repo's palette-only contract: a slot-referencing custom
opencode theme (bare ints 0–15) will NOT follow the terminal scheme in real
opencode — it renders fixed standard xterm colors. The contract's premise
("reference slots, follow the terminal automatically") holds for pi and for
Claude Code ANSI bases, but not for opencode custom themes today.

The playground documents this in its README ("Fidelity caveats") and resolves
0–15 through the live palette anyway, because previewing under a palette is
its purpose.

## Scope

Decide how my-mac-setup adopts opencode theming, given the divergence:

- Option A: rely on opencode's built-in `system` theme (palette-following by
  construction) and ship no custom opencode theme; record that decision.
- Option B: ship a custom slot-referencing theme anyway and accept that slots
  render as standard xterm colors, not the terminal palette.
- Option C: upstream ask/PR — make bare ints (or a new value form) resolve
  through the live terminal palette in custom themes.

## Open decisions

- Which option; A is the cheapest and matches the contract's intent.
- Whether the bats suite should assert anything about opencode theme files
  (today my-mac-setup ships none).
