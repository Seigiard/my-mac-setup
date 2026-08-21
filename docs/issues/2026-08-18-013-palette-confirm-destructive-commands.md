---
title: "Confirm destructive command palette commands, with the cursor starting on No"
short_description: "Confirm destructive command palette commands, with the cursor starting on No"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Pressing Enter on a highlighted row runs
it immediately (`command_palette_curses_loop`, `palette.py:811-814`). There is no confirmation step
for anything.

Today the ten declared commands are all benign, so nothing has gone wrong. That changes the moment
the palette can reach herdr's destructive built-ins — `workspace close`, `pane close`, `tab close` —
which is exactly what the catalog issue proposes, and it changes again with a fuzzy matcher whose
first result is not always what the user expected.

The combination of "fuzzy ranking picked something adjacent" and "Enter runs it instantly" is the
failure mode worth pre-empting.

## Scope

An optional `confirm = true` on a command. When set, the palette asks before running.

Two details carry most of the value:

- **The cursor starts on No.** `hota911/herdr-command-palette` does this in one line
  (`palette.sh:429-440`). A confirmation defaulting to Yes protects nobody.
- **A held key must not answer its own question.** `jeffarese/herdr-bar` designs its confirmed tab
  close around this explicitly — key repeat from the keystroke that opened the prompt can dismiss it
  before the user sees it.

The prompt should name what is about to happen concretely, including the resolved target after
placeholder expansion, not the raw command template.

## Open decisions

- Whether `confirm` is opt-in per command, or inferred for known-destructive herdr subcommands. Opt-in
  is simpler and will be forgotten; inference is safer and can be wrong about a user's own shell
  command.
- Whether a confirmed command should be exempt from frecency, since a command you hesitate over is
  not one you want floating to the top of the resting list.
- Whether this shares an implementation with the `select` sub-picker or gets its own minimal prompt.
  The palette currently opens a fresh `curses.wrapper` session per sub-picker, which is itself filed
  as a defect — a confirm prompt should not add a third one.
