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
  - theme-custom
  - herdr-theme-picker
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

## The `[theme.custom]` token vocabulary (herdr 0.9.x)

herdr's `[theme.custom]` accepts named role tokens, not just `panel_bg`. The full set — surfaced by the qintmb/herdr-theme-picker plugin, whose `bin/map.sh` keeps the authoritative list — with each token's UI role and the ghostty palette line the plugin derives it from:

| Token | UI role | Plugin derives from |
| --- | --- | --- |
| `panel_bg` | pane background | `background` |
| `sidebar_bg` | sidebar background | `background` −15% |
| `active_row_bg` | selected sidebar row | palette 0 |
| `selection_bg` | text selection bg | `selection-background` (fallback: palette 8) |
| `text` | primary text | `foreground` |
| `surface0` | sidebar row bg | palette 0 |
| `surface1` | inactive pane bg | palette 8 |
| `surface_dim` | dividers | `background` −8% |
| `overlay0` | **dim text** | palette 8 |
| `overlay1` | bright text | palette 7 |
| `subtext0` | secondary text | palette 7 |
| `accent` | active pane border/selector | palette 4 |
| `blue` | links/info | palette 4 |
| `mauve` | accent | palette 5 |
| `green` | success ✓ | palette 2 |
| `yellow` | warning | palette 3 |
| `red` | error ✗ | palette 1 |
| `teal` | now-playing | palette 6 |
| `peach` | accent | palette 9 (fallback: palette 3) |

Two distinct mappings coexist — don't conflate them. The table's third column is the **picker plugin's derivation** when it writes a `[theme.custom]` block. herdr's **native terminal theme** (`name = "terminal"`, no custom block) assigns roles differently: selected-row background and active-tab text come from ANSI 8, dim text from ANSI 7 + faint (the map earlier in this doc). A `[theme.custom]` token, once set, wins over both.

Background tokens accept the value `"reset"` — use the host terminal's background instead of a hex (verified on `panel_bg` and `sidebar_bg`).

## Fix levers

Tested against herdr 0.9.x + ghostty + Flexoki Light; the traps below were each hit in practice.

- **Theme text tokens are a trap for dimmed labels.** Setting `overlay0`/`subtext0` looks like the precise dim-text handle, but herdr applies its DIM modifier *on top of* the theme-provided color for those labels (the modifier is renderer-controlled and not disableable from theme TOML), and ghostty renders DIM as the 50/50 background blend. Any theme gray therefore washes out: `#878580` rendered as ≈`#c3c1b8`, base-700 `#575653` as ≈`#aba9a1`. Worse, once theme text tokens exist they hijack sidebar rows whose per-token `dim = false` had already fixed them. Leave text tokens unset and let the native text path honor `dim = false`.
- **`overlay1` is the exception:** inactive tab labels draw it *undimmed*, so it works as a straight color choice (tx `#100F0F` proved too heavy; base-400 `#9F9D96` reads as a distinct third level under tx and the mid grays).
- **Background/structure tokens are safe to theme** — no DIM is applied to them: `active_row_bg`, `selection_bg`, `surface0/1`, `surface_dim`, with `"reset"` for the panel and sidebar to keep the terminal background.
- **Per-token `dim = false` + explicit `fg`** in `[ui.sidebar.*]` rows controls sidebar text exactly (inline styles accept only strict `#RGB`/`#RRGGBB`); it does not reach tab labels.
- **ghostty side, global:** darken color 7 so its blended half survives (`color7 = 2T − background` per channel to land dim text on target `T`) — the only lever that reaches *other* TUIs: Claude Code's muted status-line text is ANSI 8 used directly, fixable only by a `palette = 8=` override. Side effect: non-faint color-7 text darkens toward the foreground, compressing that hierarchy.

## Shipped resolution (issue #281, herdr side)

`home/private_dot_config/herdr/config.toml` keeps `theme.name = "terminal"` and overrides only what the native mapping gets wrong on Flexoki Light: background/structure tokens from nertzy/herdr-flexoki `flexoki-light.toml` (warm ui-tier selection instead of the ANSI-8 gray slab, `surface1` restoring the inactive-tab background), `overlay1` at base-400 for tab labels, and sidebar rows carrying `dim = false` plus base-400 `fg` on the agents' alias row. Text tokens stay unset per the trap above. All hexes are Light-specific; a dark terminal theme needs them swapped or dropped. The Claude Code half (ghostty `palette = 8`) remains an open, optional tweak.

## Interaction with herdr-theme-picker

The picker's `apply.sh` deletes and rewrites the whole `[theme.custom]` block on every theme apply, so hand edits inside that block do not survive the next pick. Durable per-theme tweaks go through the plugin's own override channel instead: `# hpick-override: <token>=<hex>` comment lines in a theme's palette file (written by its `edit.sh`, applied on top of the derived tokens at apply time). The picker also pushes OSC 4/10/11 to the hosting terminal and mirrors the palette into `~/.config/ghostty/herdr-theme` when that fragment file exists and is included from the ghostty config.

## OSC residue outlives every config revert

Runtime OSC 4/10/11 color pushes live in the terminal window until explicitly reset — a ghostty config reload does **not** clear them. After reverting every config file, the window can still render the pushed palette, which looks like a config change that refuses to take effect (washed backgrounds, wrong selection colors). Reset without restarting by sending OSC 104 (whole palette), 110 (foreground), and 111 (background) to the terminal's outer PTY:

```sh
outer_tty=$(/bin/ps -eo tty,comm | awk '$2=="herdr" && $1!="??" {print "/dev/"$1; exit}')
printf '\033]104\007\033]110\007\033]111\007' >> "$outer_tty"
```

Use `/bin/ps` explicitly — in this environment `ps` is aliased to `procs`, which rejects `-eo` and leaves the tty lookup silently empty. A new terminal window is the fallback proof: it always starts from config alone.

## Verification

`ghostty +show-config | grep "^palette"` confirms user `palette` lines win over the `theme`'s values regardless of position. herdr picks up terminal palette changes on ghostty config reload; if an element lags, detach/reattach the herdr client.
