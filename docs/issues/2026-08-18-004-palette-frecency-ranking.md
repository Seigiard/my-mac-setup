---
title: "Rank the command palette's resting list by frecency"
short_description: "Rank the command palette's resting list by frecency"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin whose source lives at
`home/private_dot_config/herdr/plugins/command-palette/` and deploys to
`~/.config/herdr/plugins/command-palette/`. Its `palette.py` is a single-file Python 3 curses TUI
that runs commands declared in `~/.config/herdr/command-palette/commands.toml`.

The palette keeps no history of any kind. With an empty query it lists commands in file order
(`normalize_group_order`, `palette.py:335-339`), so opening the palette and pressing Enter does
whatever happens to be first in the TOML rather than what was last run. Every invocation costs the
same typing as the first one ever did.

Frecency — a rank that blends how often and how recently a command was chosen — fixes that without
touching the matcher.

## Scope

Persist a selection log and use it to order the list **only when the query is empty**. The moment
the user types, the fuzzy score wins outright. This separation is the whole discipline;
`crafts69guy/herdr-switchboard` applies it in `Picker::recompute` and it is what keeps learned order
from fighting search.

The zoxide formula is the one worth copying, as a *last* tiebreak:

```
score = rank * (age < 1h  ? 4
              : age < 1d  ? 2
              : age < 1w  ? 0.5
              : 0.25)
```

with amortized global aging so the file cannot grow without bound. Raycast publishes its own
ordering and places frecency fifth, below alias and title match — worth mirroring rather than
letting frecency outrank an exact hit.

Storage should be an atomic write (tempfile + `os.replace`), following
`jeffarese/herdr-bar`'s `mru.py:68-92`. `herdr-switchboard` stores an `epoch\tid` TSV capped at 200
entries (`history.rs:49-88`), which is the smaller of the two designs and probably enough here.

If the matcher moves to `fzf --filter`, the palette computes frecency itself and emits items
already sorted, then passes `--tiebreak=index` so input order is the final tiebreak.
Do **not** use `--scheme=history` for this: it strips the word-boundary bonuses to give
chronology more weight, which fixes ordering by breaking matching.

## Open decisions

- Whether frecency also applies inside the `select` sub-picker or only to the top-level command list.
- Whether project-local commands (`Project · <group>`) share one history file with global commands
  or keep separate state per project root.
- Where the state file lives. `HERDR_PLUGIN_STATE_DIR` is set only when herdr launches the command,
  so a hand-run invocation would look elsewhere — `rohankewal/herdr-nerd-font-tab-name` documents
  this trap in `lib/nftn/state.py:1-11` and deliberately uses `XDG_STATE_HOME` instead.
- Whether a command that fails should still count as a selection.
