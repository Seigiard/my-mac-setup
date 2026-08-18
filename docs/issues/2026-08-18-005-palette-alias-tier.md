---
title: Give command palette commands aliases that match by strict prefix, never fuzzy
type: idea
date: 2026-08-18
status: open
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Every command in it is reached the same
way: type letters, let the fuzzy matcher rank the list, press Enter.

That is the right default for commands you run rarely and the wrong one for the handful you run
every day. For those, fuzzy ranking is a source of uncertainty — the result depends on what else
happens to be in the list, so adding an unrelated command can change what a familiar keystroke
selects.

Both Alfred and Raycast solve this with a tier *above* the matcher: an exact alias wins outright,
without competing on score.

## Scope

Add an optional `alias` field to a command in `commands.toml`. When the query matches an alias by
strict prefix, that command sorts first and does not go through the fuzzy scorer at all. Anything
that is not an alias hit falls through to normal matching.

Two properties matter and both come from the "never fuzzy" rule:

- The alias is stable. Adding commands cannot displace it.
- The alias is predictable. `lg` means one thing forever, so it becomes muscle memory.

This composes with frecency (see the separate issue on ranking the resting list): alias is the
top tier, title match next, frecency last. Raycast's published order puts frecency fifth, below
both.

## Open decisions

- Whether an alias must be unique across global and project-local commands, and what happens when a
  project command claims an alias a global command already uses. Project commands currently render
  above global ones, so "project wins" is the consistent answer, but it means a repo can silently
  shadow a familiar key sequence.
- Whether the alias is shown in the list, and where. The right-hand keybinding panel already exists
  for a different purpose (hints scraped from Ghostty/kitty config comments).
- Whether a single-letter alias is allowed. It is the most valuable case and the easiest to collide.
