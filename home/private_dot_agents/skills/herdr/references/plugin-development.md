# Plugin development gotchas

- `herdr-plugin.toml` edits are picked up ONLY by re-running `herdr plugin link <dir>`. `server reload-config` reads `config.toml` only; `plugin disable`/`enable` flips a flag only.
- `[[panes]] width/height` in the manifest are ignored by `plugin pane open`. Pass `--width`/`--height` explicitly (PopupSize: cells or `"N%"`).
- The palette reads `~/.config/herdr/command-palette/commands.toml`, which **is** chezmoi-managed. Edit the source in the dotfiles repo, because `chezmoi apply` overwrites the live copy.
- Popups are a per-workspace singleton (`plugin_pane_open_failed: popup already open`). To open a popup from the palette (itself a popup): `type = "shell"`, `pause = false`, `nohup bash -c "sleep 0.4; herdr plugin pane open …" &`. The palette closes, and the detached process opens the popup into the freed slot.
