---
title: Match command palette queries typed in the wrong keyboard layout
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Every command title in
`home/private_dot_config/herdr/command-palette/commands.toml` is written in Latin script.

The palette opens on a keybinding, so it opens in whatever keyboard layout the user was already
typing in. With the ЙЦУКЕН layout active, typing `lazy` produces `дфян` and matches nothing — the
command is right there in the list and the query cannot reach it.

`docs/plans/2026-08-18-1254-fix-command-palette-defects-plan.md` works around this by hand: R10 adds
a per-command `shortcuts` list that literally contains the Cyrillic spellings (`дфян`, `дп`, `цы`,
`яув`, `увше`). That solves it for four commands. It does not scale — every new command needs its
Cyrillic twin written by hand, and a typo in one is invisible until the day it is typed.

## Scope

Fold the query through the ЙЦУКЕН↔QWERTY key map before matching, so a Cyrillic query matches a
Latin title with no per-command configuration.

The map is positional, not phonetic: each Cyrillic character sits on the same physical key as a
Latin one (`q`→`й`, `w`→`ц`, `e`→`у`, `r`→`к`, `t`→`е`, `y`→`н`, `u`→`г`, `i`→`ш`, `o`→`щ`, `p`→`з`,
`a`→`ф`, `s`→`ы`, `d`→`в`, `f`→`а`, `g`→`п`, `h`→`р`, `j`→`о`, `k`→`л`, `l`→`д`, `z`→`я`, `x`→`ч`,
`c`→`с`, `v`→`м`, `b`→`и`, `n`→`т`, `m`→`ь`). A single 33-entry table inverts it.

If this lands, the Cyrillic half of the plan's R10 table becomes redundant and should be deleted
from `commands.toml` rather than left to rot beside a mechanism that already covers it. The Latin
shortcuts (`lg`, `ws`) stay — they are aliases, not layout artifacts.

## Open decisions

- Whether the folded query is a second search pass or a replacement. A pass that only fires when the
  query contains a Cyrillic character costs nothing on the common path and cannot regress a Latin
  query, which argues for a second pass.
- Whether folding applies to the `shortcuts` tier too, or only to fuzzy title matching. Folding both
  is more consistent; folding only titles keeps a declared shortcut exactly literal.
- Whether other layouts matter. This machine's second layout is Russian; adding a table per layout is
  the same code and more data.
- Where the table lives given that `palette.py` is already 1577 lines in one file.
