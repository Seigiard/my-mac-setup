---
title: "Verify that a dispatched plugin action reached a terminal state"
short_description: "Verify that a dispatched plugin action reached a terminal state"
type: "idea"
category: "command-palette"
tags: ["command-palette","idea"]
date: "2026-08-18"
status: "open"
priority: "low"
---

## Why this exists

The command palette is a herdr plugin at `home/private_dot_config/herdr/plugins/command-palette/`
(deployed to `~/.config/herdr/plugins/command-palette/`). Its `plugin_action` command type runs
`herdr plugin action invoke <action>` and returns that command's exit code
(`palette.py:1465-1474`).

That exit code means only **"herdr accepted the request"**. The action itself runs elsewhere, and
whether it succeeded, failed, or never started is not in the response. A `plugin_action` whose target
script was moved or renamed exits 127 somewhere the palette never looks — the overlay closes, the
user sees nothing, and nothing happened.

`JanTvrdik/herdr-command-palette` hit this and solved it (`palette.sh:58-99`).

## Scope

After invoking, poll `herdr plugin log list` until the run reaches a terminal state, then report the
real outcome.

Details from the reference implementation that are not obvious:

- **Pull `log_id` and `plugin_id` out of the invoke response.** Do *not* derive the plugin id by
  splitting the action id on `.` — plugin ids contain dots (ours is `seigi.command-palette`).
- **Treat a still-running action at the deadline as healthy, not failed.** A long-running action is
  normal; the check is for actions that died, not for slow ones. The reference polls for ~5 seconds.

The related failure mode is that an error message printed by a failing command disappears together
with the overlay. The same repo's `die()` waits for a keypress before tearing down
(`palette.sh:13-18`). Our `shell` command type pauses for output, but our error paths do not — worth
fixing in the same pass.

`herdr plugin log list` is present in herdr 0.8.0 (`herdr plugin --help` lists `log` with the alias
`logs`), and `plugin.log.list` appears in `herdr api schema --json`.

## Open decisions

- What the palette does with a failure it detects after the overlay would normally have closed:
  keep the overlay open with the error, or raise a `herdr notification show`.
- Whether the same verification should apply to the `herdr` command type, which does capture output
  and an exit code and therefore may not need it.
- Whether the poll happens before the palette exits (blocking the user for up to five seconds) or in
  a detached follow-up that only surfaces on failure.
