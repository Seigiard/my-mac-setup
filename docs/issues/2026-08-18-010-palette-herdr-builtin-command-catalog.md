---
title: "Ship a catalog of herdr's built-in operations in the command palette"
short_description: "Ship a catalog of herdr's built-in operations in the command palette"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its global command file,
`home/private_dot_config/herdr/command-palette/commands.toml`, currently holds **ten** commands, of
which exactly two drive herdr itself (`server reload-config`, and the workspace picker).

herdr 0.8.0 exposes far more than that. `herdr api schema --json` lists 103 socket methods, and the
CLI mirrors most of them across `workspace`, `tab`, `pane`, `agent`, `worktree`, `layout` and
`session`. None of it is reachable from the palette without someone hand-writing each entry with
the correct argv.

`hota911/herdr-command-palette` has already done that work: `commands.json` is a catalog of roughly
30 herdr built-in operations with verified argv, a JSON Schema, and a weekly CI job that re-checks
the catalog against the installed herdr and files a GitHub issue when the CLI drifts.

## Scope

Transliterate that catalog into our TOML command format, or into a separate sibling `*.toml` under
`~/.config/herdr/command-palette/` so it stays distinguishable from hand-written commands.

Operations worth having that the palette cannot reach today:

- `pane split` / `swap` / `move` / `zoom` / `resize` / `focus-direction`
- `tab create` / `rename` / `move` / `close`
- `worktree create` / `open` / `remove` — this repo does worktree-isolated agent work constantly
- `layout export` / `apply` — save and restore a pane arrangement
- `agent prompt` / `wait` / `rename`

Two mechanisms from the source repo are worth taking with the data:

- **The compatibility check.** `scripts/check-compat.sh:120-142` parses `herdr <group> <sub> -h` and
  guards against herdr's real quirk that an unknown *group* falls back to top-level help with exit 0.
  That guard was written from measurement, not assumption.
- **The fake `herdr` test stub.** 590 lines reproducing real 0.8.0 output, driven by `HERDR_BIN_PATH`
  and recording every call so a test can assert the exact argv produced. Our palette also resolves
  the binary through `HERDR_BIN_PATH` (`palette.py:1366`), so the stub is directly usable.

The upstream repo is MIT. It is also two days old with one star, so the catalog is worth verifying
rather than trusting.

## Open decisions

- Whether to import the catalog as data or to keep it upstream and pull it via
  `home/.chezmoiexternal.toml`, which is how this repo already manages external archives.
- Whether destructive operations (`workspace close`, `pane close`) belong in the catalog at all
  without the confirmation step filed separately.
- How to keep the catalog from swamping the ten hand-written commands that get used daily. This is
  the strongest argument for the alias tier and for frecency landing first.
