---
title: "Remove the command palette's three sleep-based focus workarounds"
short_description: "Replace three 0.2–0.4 second focus delays only after user-run `chezmoi apply` trials establish whether popup teardown races on a loaded Herdr 0.8.0 session."
type: "bug"
category: "command-palette"
tags: ["command-palette","bug"]
date: "2026-08-18"
status: "open"
priority: "low"
parent-plan: "docs/plans/2026-08-18-1254-fix-command-palette-defects-plan.md"
---

## Why this exists

The herdr command palette (`home/private_dot_config/herdr/plugins/command-palette/`)
lands focus after three of its commands by sleeping, not by sequencing. Three sleeps with
three different constants:

- `palette.py`, the workspace picker — 0.2 s before `herdr workspace focus`, in a detached
  `bash -lc` (`pick_workspace`).
- `palette.py`, `tab_run` — 0.2 s before `herdr tab focus`, same shape
  (`run_command_with_variables`), overridable per command via `focus_delay`.
- `home/private_dot_config/herdr/command-palette/commands.toml:15` — 0.4 s before the
  lazygit popup opens.

A sleep is a bet on how long herdr takes to restore focus to the pane that opened the
overlay. It is not a guarantee, and on a loaded machine it is the wrong bet.

This is requirement R5 of
`docs/plans/2026-08-18-1254-fix-command-palette-defects-plan.md` (unit U7), the one defect
of six that the plan left unfixed. Every other unit shipped; R5 is **not** met.

## Scope

The unit cannot be finished from the checkout, which is why it is filed rather than done.
Its first step is an experiment against a live herdr, and that needs `chezmoi apply` — a
command this repo forbids on the host. So the work alternates between two owners:

1. **Executor** — remove the `tab_run` sleep and commit.
2. **User** — `chezmoi apply`, then run `Lazygit in new tab` and `Switch workspace`, and
   report where focus landed.
3. **Executor** — remove the remaining two sleeps, or replace all three with an explicit
   sequence, according to what step 2 showed.
4. **User** — `chezmoi apply` and re-run both commands to confirm.

Start by testing whether the sleeps are load-bearing at all. herdr 0.8.0's own API schema
declares `PluginPanePlacement` as `["overlay", "popup", "split", "tab", "zoomed"]`, and
`open.py` opens the palette with `--placement popup`. The documented hazard — herdr killing
the pane's whole process group on close, which `nohup` does not escape — is described for
**overlay** panes. If popup panes do not race, all three sleeps are simply removable.

`tab_run` is the one to test first: either the new tab has focus or it does not, which is
easy to judge by eye. The workspace-picker sleep fires during a workspace switch, where a
wrong outcome is harder to attribute.

If the race is real, apply one fix consistently:

- **(a)** Focus synchronously, then close the pane explicitly with
  `herdr pane close $HERDR_PANE_ID`.
- **(b)** Focus after the TUI is torn down and immediately before process exit.

Prefer (b) inside `palette.py` — it needs no new herdr call and matches the existing
`curses.wrapper` teardown, which already ends before `run_command` runs. Use (a) for the
`commands.toml` lazygit entry, which is a shell command with no TUI to tear down.

Do not plan around `herdr wait`: it does not exist in herdr 0.8.0. `herdr agent wait --until
<status>` exists but waits on agent status, not on focus readiness.

## Open decisions

- Whether popup panes race at all. This is the durable finding the unit buys, and it is
  worth recording in the commit message whichever way it goes.
- What to do if two runs disagree. A flaky focus bug is worse than a 0.2 s delay, so keep
  the sleeps and say so rather than removing them on one trial that happened to look right.
- Whether `focus_delay` stays as a per-command escape hatch in `commands.toml` once the
  sleeps are gone.
