---
title: Add clickable Herdr focus notifications without a Rust build dependency
type: follow-up
date: 2026-08-18
status: open
---

## Why this exists

`yankewei/herdr-focus-notify` sends a macOS notification when a Herdr agent becomes `blocked` or
`done`. Clicking the notification activates the terminal and focuses the matching Herdr pane. The
behavior is useful, but the upstream plugin's `herdr-plugin.toml` runs `cargo build --release` during
installation and requires `vjeantet/tap/alerter` at runtime.

This repository does not currently install Rust or `alerter`. Adding both for one small integration
would expand the machine setup and make clean-machine installation compile a Rust binary from an
external repository.

The repository already installs `terminal-notifier` in
`home/private_dot_config/brewfiles/Brewfile.macos`. `terminal-notifier` supports `-execute` and
`-activate`, so it can provide clickable notifications without another notification backend. The
local Herdr plugins under `home/private_dot_config/herdr/plugins/` use shell or Python and are linked
by tolerant scripts in `home/.chezmoiscripts/`.

## Scope

Evaluate two implementations and add the selected one:

1. Install `yankewei/herdr-focus-notify` unchanged, including managed Rust and `alerter`
   dependencies.
2. Implement a small local Herdr plugin with shell or Python plus the existing
   `terminal-notifier` formula.

The implementation must subscribe to `pane.agent_status_changed`, notify only for `blocked` and
`done`, and include the pane identifier in a safely quoted click command. Clicking the notification
must activate the terminal that owns the Herdr session and run `herdr agent focus <pane-id>`.

If the local implementation learns terminal ownership from `pane.focused`, store the binding in the
Herdr plugin state directory. It must suppress notifications only when it can confirm that the user
already sees the target pane. Ambiguous focus state must produce a notification.

Add the plugin source under `home/private_dot_config/herdr/plugins/`, add a tolerant link-and-enable
script under `home/.chezmoiscripts/`, and add smoke tests in `tests/smoke.bats`. Include a manual test
that verifies notification display, click activation, pane focus, duplicate replacement, and cleanup.

## Open decisions

- Whether the smaller local implementation is preferable to tracking upstream behavior and fixes.
- Whether `terminal-notifier -execute` provides reliable click handling on the current macOS version.
- Whether terminal activation should use an explicit configured bundle identifier or a per-workspace
  binding learned from `pane.focused` events.
- Which upstream behaviors are required for the first version: duplicate suppression, automatic
  removal after pane focus, agent icons, timeout configuration, and debug logs.
