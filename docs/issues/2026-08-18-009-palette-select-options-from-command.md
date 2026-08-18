---
title: Let a command palette select command generate its options from a shell command
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its `select` command type opens a second
fuzzy list and then runs a nested command with the chosen `{value}`.

The options for that list are **static**. They come only from `[[options]]` entries written into the
TOML (`command_choices`, `palette.py:980-998`). So a `select` over git branches, agent names, open
ports, or anything else that changes is impossible to express — the file would have to be rewritten
whenever the world moves.

`arjenblokzijl/herdr-launcher` solves this with one schema field: `choices_command` runs a shell
command and every stdout line becomes a fuzzy-selectable choice (`run_choices`, `main.rs:278-295`).
That is how its bundled workflow lists git branches and its agent roster.

## Scope

Add `choices_command` alongside `[[options]]` on the `select` type. Static options stay supported;
the two are alternatives, not layers.

One design detail from the reference implementation is worth keeping: a command that returns **zero**
choices still renders a Select, and is never silently downgraded to unvalidated free text
(`build_input`, `main.rs:297-317`). Degrading to a text field would let a broken command quietly turn
a constrained choice into arbitrary input.

One thing the reference gets wrong and we should not copy: `run_choices` swallows every failure into
an empty list, so a broken `choices_command` is indistinguishable from one that legitimately produced
nothing. Distinguish them and say which happened.

The command runs when the sub-picker opens, and it blocks. For a slow command that is a frozen
overlay. The palette has no async anywhere today, so this either accepts the block, or arrives with
the streaming work described in the transport and event-loop issues.

## Open decisions

- What environment `choices_command` runs in. The palette already exports `HERDR_COMMAND_PALETTE_*`
  and expands `{target_cwd}` / `{project_root}` placeholders; the option command should see the same
  context, in particular the originating pane's cwd rather than the palette process's.
- Whether an option line can carry a label and a value separately — a tab-delimited two-column
  convention is the cheap answer, and matches what `--with-nth` does for fzf-based pickers.
- Whether to cache the result across reopenings, and what invalidates it.
- Whether a timeout is needed, and what the palette shows while waiting.
