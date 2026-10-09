# Workspaces, tabs, and notifications

## Workspace and tab labels

`workspace create` and `tab create` take `--label`. Without it, the name defaults to the cwd or a number. A manual tab label is presentation metadata and is independent of allocator-owned agent aliases.

## Notifications (best-effort)

```bash
herdr notification show "PM: decision ready" --body "pick 1 or 3" --sound request
```

If notifications are disabled in `~/.config/herdr/config.toml`, the command returns `{"shown": false, "reason": "disabled"}` and does nothing. A toast is a nudge, not a channel: never depend on it being seen.
