# herdr-core templates

These templates are managed for `hc run` child roles.

## Verified `hc` facts

- `hc` reads only top-level `*.md` files in this directory.
- A template name is its filename without `.md`. Keep the `name` field equal to that filename.
- Frontmatter uses one plain `key: value` entry per line. Comments make a template invalid. Keep comments out of template frontmatter.
- The `command` field is one shell line. `hc` runs it with `sh -c`.
- `hc` sends the template body, one blank line, and the task as the first message.
- An agent caller adds `<hc from="..." reach="...">`. A plain shell caller does not add that tag. The `reach` attribute is the only caller address in the message.
- The template cannot see the caller's `HC_TERMINAL_ID`. Its `$HC_TERMINAL_ID` belongs to the child.
- Notes stay enabled by default. No `config.toml` is needed.
- If a future codex template is added, its command must include `--no-daemon`.
