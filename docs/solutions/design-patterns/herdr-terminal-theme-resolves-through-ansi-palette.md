---
title: Herdr's terminal theme resolves through the ANSI palette — map indexes before tuning colors
date: 2026-09-17
category: design-patterns
module: herdr
problem_type: design_pattern
component: configuration
severity: medium
related_components:
  - ghostty
applies_when:
  - "A herdr UI element (dim text, selection background, tab colors) is unreadable or the wrong color"
  - "Tuning colors while herdr runs with theme.name = \"terminal\", which delegates its palette to the host terminal"
  - "Deciding whether a color fix belongs in the ghostty theme/palette or in herdr's own config"
  - "Diagnosing which ANSI index paints which UI element in any terminal-palette-driven TUI"
symptoms:
  - "Dim/secondary text (tab labels, branch rows, agent second rows) is near-invisible on a light theme"
  - "Overriding the ANSI index that appears to match the bad color changes an unrelated element instead"
  - "A color computed nowhere in any config file shows up in the UI"
tags:
  - herdr
  - ghostty
  - flexoki
  - ansi-palette
  - sgr-faint
  - dim-text
  - terminal-theme
---

# Herdr's terminal theme resolves through the ANSI palette — map indexes before tuning colors

## Context

herdr runs with `theme.name = "terminal"`: it carries no palette of its own and paints its UI with the host terminal's ANSI colors (see the rationale comment in `home/private_dot_config/herdr/config.toml`). ghostty supplies those colors from its theme (`Flexoki Light` at the time of writing). When a herdr UI element renders unreadably, the observed color often matches **no line in any config**, because two indirections stack:

1. herdr assigns UI roles to ANSI indexes internally, and the assignment is not what the role names suggest.
2. ghostty renders SGR faint (dim) text by blending the color 50/50 with the background, producing a hex that exists in neither palette.

Concretely: Flexoki Light's color 7 `#6f6e69` blended half-and-half with background `#fffcf0` yields `#b7b5ac` — which happens to equal Flexoki base-300, inviting the wrong conclusion that some palette slot is set to base-300. Guessing an index from the observed hex therefore fails.

## Pattern

**Don't guess — map.** Override every ANSI index at once with a unique, loud, nameable hue in the ghostty config, reload (⌘⇧,), and take one screenshot. Every UI element announces its index by color; faint variants show up as the washed-out version of their index's hue.

```
# DIAGNOSTIC PALETTE — remove after mapping; theme defaults return with it.
palette = 0=#ff0000
palette = 1=#ff8800
palette = 2=#ffee00
palette = 3=#00cc00
palette = 4=#00ffff
palette = 5=#0044ff
palette = 6=#cc00ff
palette = 7=#ff00aa
palette = 8=#663300
palette = 9=#aaffaa
palette = 10=#006644
palette = 11=#99ccff
palette = 12=#000066
palette = 13=#660033
palette = 14=#999900
palette = 15=#444444
```

One round-trip beats changing one index per screenshot; the single-index probe is still useful to confirm a suspicion.

## The map (herdr 0.9.x UI roles → ANSI indexes)

| herdr UI element | ANSI index |
| --- | --- |
| Sidebar section headers (`machines`, `agents`), workspace names | 7 |
| Dim text: inactive tab labels, branch rows, agent second rows | 7 + SGR faint |
| Selected row background (sidebar and agents), separator line, active-tab text | 8 |
| Active tab background, `menu` link, inline code/links in panes | 4 |
| Agent status circles, machine names (`Local`, `mbp2026`), status dots | 2 |
| Status-bar accents (`[main]`, permission hints) | 5 |

The load-bearing fact: **dim text is not its own palette slot.** It is color 7 with the faint attribute, and ghostty's faint rendering (50% blend toward background, not configurable) is what produces the final hex: `dim = (color7 + background) / 2`, per channel.

Other TUIs in the same terminal take a different road to the same unreadable gray: Claude Code paints its muted status-line text (token counter, key hints) with ANSI 8 directly, which Flexoki Light sets to `#b7b5ac` — numerically identical to herdr's 7-plus-faint blend. Two mechanisms, one symptom; a terminal-side fix must cover both indexes, and a herdr-side fix covers neither of the others.

## Fix levers

- **ghostty side:** darken color 7 so its blended half survives on the background. The blend math runs backwards: to land dim text on a target tone `T`, set `color7 = 2T − background` per channel. On Flexoki Light, `7=#403e3c` (base-800) yields dim ≈ `#9f9d96`; `7=#282726` (base-900) yields dim ≈ `#93918b`. Side effect: non-faint color-7 text (headers, workspace names, gray CLI output) darkens toward the foreground, compressing that hierarchy.
- **herdr side:** suppress the faint attribute per sidebar token with `dim = false` in `[ui.sidebar.*]` rows — fixes those rows only, not tab labels. Inline token styles accept only strict `#RGB`/`#RRGGBB` foregrounds, which would survive a theme switch as the wrong color, so prefer attribute toggles over hex (same constraint documented in `config.toml`).

## Verification

`ghostty +show-config | grep "^palette"` confirms user `palette` lines win over the `theme`'s values regardless of position. herdr picks up terminal palette changes on ghostty config reload; if an element lags, detach/reattach the herdr client.
