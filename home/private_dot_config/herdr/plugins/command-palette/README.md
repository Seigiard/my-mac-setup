# Herdr Command Palette

Local Herdr plugin that opens an overlay command palette and runs commands from a
user-editable JSON file.

## Install/link

This dotfiles repo links the plugin from:

```bash
~/.config/herdr/plugins/command-palette
```

Manual development link:

```bash
herdr plugin link ~/.config/herdr/plugins/command-palette
herdr plugin action list --plugin seigi.command-palette
```

## Keybinding

Configured in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "cmd+shift+p"
type = "plugin_action"
command = "seigi.command-palette.open"
description = "command palette"
```

If your terminal does not pass Command/Super keys through to terminal apps,
change this to a prefix binding such as `prefix+space` or `prefix+shift+p`.

## Commands

The plugin ships read-only defaults in `defaults/commands.json`. On first run it
seeds the user-editable command list at:

```bash
~/.config/herdr/command-palette/commands.json
```

That runtime file is intentionally not managed by chezmoi, so live edits are not
overwritten by `chezmoi apply`. The palette also supports
`HERDR_COMMAND_PALETTE_CONFIG=/path/to/commands.json` for experiments.

Supported command types:

- `herdr`: runs `HERDR_BIN_PATH` with an argv array.
- `pane_run`: sends a shell command to the pane that opened the palette.
- `tab_run`: creates a new Herdr tab and runs a shell command there.
- `shell`: runs a shell command inside the overlay and pauses for output.
- `overlay_shell`: replaces the overlay with an interactive shell command.
- `plugin_action`: invokes another Herdr plugin action.

Each command may include a `group` field. The palette shows section headers when
the search query is empty, and includes the group label in search results. If
`group` is omitted, the command falls back to `Other`.

Example:

```json
{
  "group": "Apps",
  "title": "Lazygit in new tab",
  "description": "Open a new tab and run lazygit",
  "type": "tab_run",
  "label": "lazygit",
  "command": "lazygit"
}
```

String fields support these placeholders:

- `{config_file}`, `{config_file_q}`
- `{config_dir}`, `{config_dir_q}`
- `{plugin_root}`, `{plugin_root_q}`
- `{state_dir}`, `{state_dir_q}`
- `{target_pane}`, `{target_pane_q}`
- `{target_cwd}`, `{target_cwd_q}`
