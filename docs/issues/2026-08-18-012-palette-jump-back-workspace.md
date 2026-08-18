---
title: Jump back to the previous workspace from the command palette
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its `workspace_picker` command type can
focus any workspace, but it keeps no memory of where you came from.

With five workspaces open and agents running in most of them, the common motion is not "pick a
workspace" — it is "go back to the one I was just in". Today that means opening the picker and
finding it again by eye, every time.

## Scope

A depth-1 most-recently-used record: one workspace id, and a command that focuses it.

`thanhdat77/herdr-navigator` implements this in about 20 lines (`app.rs:693-712`) and its three
correctness details are the whole design:

- **Record only on a real transition.** The origin and destination must differ, or a no-op focus
  overwrites the thing you wanted to go back to.
- **Record only for actions that actually move you** — focusing a workspace or an agent, opening a
  project. Running a shell command in place must not count.
- **Self-heal when the target is gone.** If the remembered workspace no longer exists, delete the
  state file and report it plainly rather than failing on a stale id.

It also offers pinning the previous workspace to the top of the picker rather than requiring a
separate command, which is arguably the better interface: one list, previous workspace first.

Storage is a plain text file holding one id. It should be written atomically and should not live in
`HERDR_PLUGIN_STATE_DIR` — herdr sets that only when herdr launches the command, so a hand-run
invocation would look in a different place. `rohankewal/herdr-nerd-font-tab-name` documents that
trap in `lib/nftn/state.py:1-11`.

## Open decisions

- Whether to record transitions the palette did not cause. The user switches workspaces with
  keybindings far more often than through the palette, so a palette-only record will be stale most
  of the time. Doing this properly means subscribing to `workspace.focused` from a background
  process — which is the event-driven work filed under the transport and warm-index issues.
- Whether depth 1 is enough or whether a short ring is worth it.
- Whether the same idea should extend to tabs and panes once those switchers exist.
