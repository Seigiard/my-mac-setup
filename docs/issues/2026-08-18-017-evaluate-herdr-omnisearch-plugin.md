---
title: "Evaluate herdr-omnisearch as a sibling plugin for searching pane contents"
short_description: "Evaluate herdr-omnisearch as a sibling plugin for searching pane contents"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). It searches exactly one thing: its own
declared command list. It cannot search pane contents, scrollback, agent conversations, files, or
git state.

That gap is real on this machine. With nine panes open, most of them agent sessions, "which pane was
the one where that error appeared" has no answer short of looking through them by hand.

`dmnkf/herdr-omnisearch` (MIT, Python 3, stdlib only) fills exactly that gap and does not overlap
with ours. It indexes:

- every live pane's recent terminal output,
- pane metadata as searchable text — workspace, ids, label, agent, status, cwd serialised into one
  document, so ids and paths fall out of the same index with no special-casing,
- archived agent conversations on disk, including `~/.claude/projects/*/*.jsonl`.

Search is SQLite FTS5 with BM25 ranking, plus a typo-tolerant second pass (trigram-pruned, bounded
Levenshtein) that runs only when the exact pass comes back thin. A background watcher subscribed to
herdr's event socket keeps the index warm, so the picker opens against SQLite rather than doing I/O.

It ships as a standalone CLI (`herdr-omnisearch pick | search | preview`), so it installs as its own
plugin on its own keybinding. No integration work with our palette is required.

## Scope

Decide whether to install it, and on what terms. Adding it would mean an entry in
`home/.chezmoiexternal.toml` or a plugin install step, plus a keybinding in
`home/private_dot_config/herdr/config.toml` alongside the existing `cmd+shift+p` and `prefix+space`.

If we do not install it, its search core is liftable independently: `tokens`, `token_trigrams`,
`edit_distance_limited`, `score_token_candidate` and `candidate_tokens_for_term` are roughly 150
lines depending on nothing but a sqlite connection.

## Risks that must be settled first

- **It has been observed scrolling the user's panes.** An open issue on the repo reports the live
  indexer harvesting alternate-screen history by wheeling the viewport. That is the cost of a
  background daemon reading live terminals, and it would affect panes with agents running in them.
  This is the blocking question.
- **It reads agent conversation logs into a local SQLite database.** Disabled by default
  (`[archive] enabled = false`) and written to a private directory, but it is a privacy surface we do
  not currently have.
- **Single maintainer, ~30 commits, about three weeks old.** Version drift too: the manifest says
  0.6.7 while the newest release tag is v0.4.6.
- **5,318 lines in one file** — the same shape as our own `palette.py`, three times over.
- It requires `sqlite3` compiled with FTS5 in the system Python, which is not guaranteed.

## Open decisions

- Whether to run it with archive indexing off, which removes the privacy surface and keeps the live
  pane search that is the actual draw.
- Whether the pane-scrolling bug is reproducible on herdr 0.8.0, and whether the watcher can be run
  in a read-only mode that avoids it.
- Whether this belongs in this repo at all, or is better kept as a manual install noted in
  `docs/agent-setup-inventory.md`.
