---
title: "Let a command palette command ship with its own scripts as a bundle"
short_description: "Let a command palette command ship with its own scripts as a bundle"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Commands live in a flat set of TOML files:
`~/.config/herdr/command-palette/commands.toml` plus sibling `*.toml`, and project-local
`.herdr/command-palette/*.toml` discovered by walking up from the pane's cwd
(`command_data_files` and `project_command_dir`, `palette.py:211-234`).

A command that needs more than one shell line has nowhere to put it. The options today are to inline
a long `zsh -ic '...'` string — which the existing commands already do — or to reference a script
somewhere else on disk that nothing ties back to the command. Deleting a command leaves its script
orphaned; moving the dotfiles repo breaks the path.

`arjenblokzijl/herdr-launcher` solves this with bundle directories and one exported variable:

```
myflow/
  myflow.toml     # command = "bash $HERDR_WORKFLOW_DIR/run.sh"
  run.sh
  list.sh
```

`$HERDR_WORKFLOW_DIR` points at the bundle, so scripts are referenced relocatably. Its README frames
the value correctly: **delete the folder, delete the task.**

## Scope

Recognise a directory under a command-palette config dir as a bundle: its TOML declares the command,
and an exported directory variable anchors any scripts beside it.

This matters most for project-local commands. A repo that ships `.herdr/command-palette/` today can
only declare one-liners; with bundles it can ship a real script next to the command that runs it, and
the whole thing travels with the repo.

The palette already exports `HERDR_COMMAND_PALETTE_*` variables to shell commands
(`command_environment`, `palette.py:1334-1349`) and already resolves `{project_root}`, so the
mechanism exists — what is missing is a per-command anchor.

## Open decisions

- The variable name. `HERDR_COMMAND_PALETTE_COMMAND_DIR` is consistent with the existing prefix but
  long; the placeholder form `{command_dir}` / `{command_dir_q}` should exist either way to match how
  every other context value is exposed.
- Whether a bundle may declare more than one command, or exactly one.
- Whether bundled scripts need an executable-bit check at load time, since a non-executable script
  fails at run time with an error the overlay may swallow.
- How this interacts with chezmoi. Global bundles under `~/.config/herdr/command-palette/` would be
  managed from `home/private_dot_config/herdr/command-palette/`, so a bundle's scripts become
  chezmoi-managed files and need the usual template/permission handling.
