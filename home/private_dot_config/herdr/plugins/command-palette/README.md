# Herdr Command Palette

Local Herdr plugin that opens an overlay command palette and runs user-editable
global and project-local commands.

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

The plugin also exposes `seigi.command-palette.smart_close`, used by the
dotfiles' Cmd-W bridge to close the focused pane when a tab has multiple panes,
then close the current tab when the workspace has multiple tabs, but never close
the last tab in a workspace. Use Herdr's explicit close-workspace binding for
workspace destruction.

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

The plugin ships read-only defaults in `defaults/commands.toml`. On first run it
seeds the user-editable global command list at:

```bash
~/.config/herdr/command-palette/commands.toml
```

That runtime file is intentionally not managed by chezmoi, so live edits are not
overwritten by `chezmoi apply`. The palette also supports
`HERDR_COMMAND_PALETTE_CONFIG=/path/to/commands.toml` for experiments.

You can also add one command per file beside it:

```bash
~/.config/herdr/command-palette/*.toml
```

Project-local commands are discovered by walking up from the pane's working
directory until a repo provides:

```bash
.herdr/command-palette/commands.toml
.herdr/command-palette/*.toml
```

Project commands are read-only from the palette's point of view and render above
global commands under `Project · <group>` headings.

Validate command files with the plugin itself:

```bash
python3 ~/.config/herdr/plugins/command-palette/palette.py --validate \
  ~/.config/herdr/command-palette/commands.toml \
  .herdr/command-palette/*.toml
```

The validator parses TOML and checks the command-palette schema: required title
or name, supported command types, valid nested `run` type, and selectable options
for `select` commands.

Supported command types:

- `herdr`: runs `HERDR_BIN_PATH` with an argv array.
- `pane_run`: sends a shell command to the pane that opened the palette.
- `tab_run`: creates a new Herdr tab and runs a shell command there.
- `shell`: runs a shell command inside the overlay and pauses for output.
- `overlay_shell`: replaces the overlay with an interactive shell command.
- `plugin_action`: invokes another Herdr plugin action.
- `workspace_picker`: opens a navigable workspace switcher.
- `select`: opens a second fuzzy list, then runs a nested command with `{value}`.
- `form`: prompts for text, then runs a nested command with `{value}`.

Each command may include a `group` field. The palette shows section headers when
the search query is empty, and includes the group label in search results. If
`group` is omitted, the command falls back to `Other`.

Example. One-file TOML commands may use `name` instead of `title`; omitting
`type` defaults to `shell` when a `command` is present:

```toml
name = "Search Google"
description = "Prompt for a query"
type = "form"
command = "open 'https://www.google.com/search?q={value_url}'"

[form]
prompt = "Search Google for"
placeholder = "herdr command palette"
```

`select` commands use `[[options]]`; options without `label` are non-selectable
headings/spacers:

```toml
name = "Open Git Remote"
type = "select"
command = "gh repo view --web {value_q}"

[[options]]
heading = "Repos"

[[options]]
label = "my-mac-setup"
value = "seigiard/my-mac-setup"
description = "dotfiles"
```

For `select`/`form`, either place the nested runnable command fields at the top
level, or use an explicit `run` table:

```toml
name = "Open docs"
type = "select"

[run]
type = "overlay_shell"
command = "open {value_q}"

[[options]]
label = "Herdr"
value = "https://herdr.dev"
```

String fields support these placeholders:

- `{config_file}`, `{config_file_q}`
- `{config_dir}`, `{config_dir_q}`
- `{plugin_root}`, `{plugin_root_q}`
- `{state_dir}`, `{state_dir_q}`
- `{target_pane}`, `{target_pane_q}`
- `{target_cwd}`, `{target_cwd_q}`
- `{project_root}`, `{project_root_q}` when a project-local command directory is found
- `{value}`, `{value_q}`, `{value_url}` for `select` and `form` commands

Shell commands also receive `HERDR_COMMAND_PALETTE_*` environment variables for
the config path, target pane/cwd, plugin root, state dir, and selected/input
value.
