---
title: "opencode resolves bare-int theme values through a hardcoded standard-16 table, not the live terminal palette"
short_description: "opencode resolves bare-int theme values through a hardcoded standard-16 table, not the live terminal palette"
type: "follow-up"
category: "command-palette"
tags: ["command-palette","follow-up"]
date: "2026-08-20"
status: "done"
priority: "low"
closed: "2026-08-21"
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

## Resolution

**Option A.** my-mac-setup relies on opencode's built-in `system` theme and
ships no custom opencode theme. Rationale: `system` is the only theme that
queries the live terminal palette (`renderer.getPalette({size: 16})`), so it
is palette-following by construction — exactly the contract's intent — while
a custom slot-referencing theme would render the fixed xterm-16 table. Cheap
to reverse if opencode ever makes bare ints palette-aware (option C remains
open upstream).

Checked on close (2026-08-21) — the repo already implements A in full, so no
config or test change was needed:

- `home/private_dot_config/opencode/tui.json` pins `"theme": "system"`.
  Key location verified against opencode's themes docs (opencode.ai/docs/themes):
  the TUI theme lives in `tui.json` under `theme`; `system` is built-in and
  "automatically adapts to your terminal's color scheme". The explicit pin
  matters because opencode's default theme is `opencode`, not `system`.
- No file under `home/private_dot_config/opencode/themes/` — no custom theme
  ships; `home/.chezmoiremove` retires the old forced theme
  (`.config/opencode/themes/flexoki-light-forced.json`) on machines that
  deployed it.
- Bats already asserts the decision (second open decision answered "yes,
  and it does"): `tests/smoke.bats` "coding agents use terminal color
  palettes" checks `.theme == "system"` in the deployed
  `~/.config/opencode/tui.json` and that the retired theme file is absent;
  `tests/templates.bats` ".chezmoiremove deletes the retired opencode forced
  theme" guards the removal entry in the source tree.
- Upstream behavior reference: sst/opencode @
  `ad192a59b5517fb432bc5f4d27f131d605a22beb` (the commit examined in
  "Why this exists").
