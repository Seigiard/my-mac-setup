# herdr-focus-notify

Clickable macOS notification when a herdr agent goes `blocked` or `done`.
Clicking the toast activates the terminal that runs herdr and runs
`herdr agent focus <pane-id>`.

Local reimplementation of the core of
[yankewei/herdr-focus-notify](https://github.com/yankewei/herdr-focus-notify)
without its Rust build step or third-party notifier backend: one Python script
plus the `terminal-notifier` formula this repo already installs.

## How it works

- Subscribes to `pane.agent_status_changed`; herdr delivers the payload in
  `HERDR_PLUGIN_EVENT_JSON`.
- Notifies only for `agent_status` `blocked` or `done`.
- `-group herdr-<pane-id>` keeps one toast per pane: a newer status replaces
  the older notification instead of stacking.
- The click command is built with `shlex.quote` on both the herdr binary path
  and the pane id, so no event value is ever interpreted as shell syntax.

## Configuration

The terminal activated on click defaults to ghostty
(`com.mitchellh.ghostty`), because this repo's ghostty config auto-launches
herdr. To activate another terminal, write its bundle identifier as the single
line of:

```
$(herdr plugin config-dir seigi.focus-notify)/terminal-bundle-id
```

For example `net.kovidgoyal.kitty`.

## v1 limitations (deliberate)

- No focus suppression: a notification is sent even when the pane may already
  be visible. Ambiguous focus state must notify, and always-notify is the
  simplest correct version of that rule.
- No terminal learning from `pane.focused` and no state files.
- No auto-removal of a toast once the pane gets focused; `-group` replacement
  and manual dismissal cover cleanup.
- No agent icons, sounds, or timeout configuration.

## Manual verification (needs a live macOS session)

1. `herdr plugin list` shows `seigi.focus-notify` linked and enabled.
2. `herdr plugin action invoke seigi.focus-notify test` (or the palette action
   "Focus notify: send test notification") shows a toast titled
   "Focus notify test needs your input".
3. Let an agent in some pane reach `blocked` or `done` while another app is
   frontmost: a toast appears naming the agent and the pane.
4. Click the toast: the terminal comes to the front and the matching pane
   gets focused (`herdr agent focus` ran).
5. Duplicate replacement: trigger two status changes for the same pane; the
   second toast replaces the first instead of stacking in Notification Center.
6. Cleanup: dismissed toasts leave nothing behind (`herdr plugin log
   seigi.focus-notify` shows no errors; the plugin writes no state files).
