# Agent Setup Inventory

The repository reproduces the selected Claude Code, OpenCode, and Pi setup.
Codex, Gemini CLI, and GitHub Copilot are intentionally out of scope.

## Skill Ownership

[The upstream skills manifest](../home/private_dot_config/agent-skills/manifest)
is the source of truth for selected upstream skills. `~/.local/bin/skills`
installs them globally under `~/.agents/skills`; its global lock owns those
upstream children at `${XDG_STATE_HOME:-$HOME/.local/state}/skills/.skill-lock.json`.

[The repository-owned skills manifest](../home/private_dot_config/agent-skills/repository-owned)
reserves names managed from `home/private_dot_agents/skills/`. Claude Code
receives symlink adapters under `~/.claude/skills`; OpenCode and Pi discover
`~/.agents/skills` natively. No effective skill name may have both owners.

`open-questions` is explicit-only: Claude and Pi receive a manual skill
adapter, while OpenCode receives a command adapter only.

`handoff` is absent and is not managed. `linear-cli`, not `linear`, is the
selected upstream skill name.

## Skills CLI

Use `skills add <source> [skill...]`, `skills remove <source> <skill...>`,
`skills update [skill...]`, or `skills sync`. `sync` installs every manifest
entry and reports unmanaged or obsolete lock entries with explicit commands to
remove them or preserve them through `skills add`. Before a managed `add` or
`remove`, the wrapper requires a clean chezmoi source branch, pulls it with
`--ff-only`, and refreshes the live manifest. After the local operation, it
captures the manifest with `chezmoi add`, commits only that file, and pushes the
commit. Removing one skill from a wildcard source is rejected because the
manifest cannot represent "all except this skill". `sync` never removes drift
automatically. Restart Claude Code, OpenCode, and Pi after installation or
discovery configuration changes.
Successful upstream CLI output is hidden by default; use `skills --verbose
<command>` to restore it. Failed commands always replay the captured diagnostics.

## Plugin-Owned Functionality

Portable bare `ce-*` skills replace the former client-specific Compound
Engineering providers.

Claude retains `playwright`, `plugin-dev`, `security-guidance`, and
`typescript-lsp` for non-skill functionality. Its Compound Engineering,
`frontend-design`, and `claude-md-management` plugins are retired
(`claude-md-improver` overlaps with the manifest-installed `improve-claude-md`
skill, which all three agents see; the `/revise-claude-md` command goes with
it). OpenCode does
not install the Compound Engineering plugin or its generated convenience
commands. Pi does not install the Compound Engineering package; its managed
extension list remains the source of truth for non-skill packages.

`open-source-librarian` is the repository-managed Claude agent.

## Agent Intercom

Claude Code, OpenCode, and Pi sessions launched inside Herdr join the same local
Agent Intercom broker under their Herdr alias when the launcher can resolve one.
The locked package set lives at
`~/.local/share/agent-intercom`; a managed launcher selects Claude's live MCP
transport while preserving native Claude arguments and tool restrictions,
exports the OpenCode name, or passes Pi's normal `--name` option.
The Claude bridge discards `cci`'s synthetic permission selector so explicit
caller flags, then project and user settings, retain their native precedence.
Claude and Pi utility launches bypass Intercom unchanged. Nested, unidentified,
and non-Herdr launches do the same for all three clients; OpenCode does not
classify subcommands at the launcher boundary.

OpenCode loads only the server plugin, so the Intercom `/intercom`, `Alt+M`, and
`Alt+I` TUI conveniences are intentionally absent. Pi loads the native extension.
Codex remains outside this slice because its tested wakeable and proactive-tool
paths register separate Intercom identities.

### Runtime storage

The launcher exports `INTERCOM_DIR`, defaulting to
`${XDG_STATE_HOME:-$HOME/.local/state}/agent-intercom`; an explicit nonempty
`INTERCOM_DIR` takes precedence. This shared directory holds the broker sockets,
credentials, Intercom configuration, and message state for all three clients.
It is separate from the managed Pi configuration tree and the installed package
root. Upstream creates the directory with mode `0700` and credential files with
mode `0600`.

The adapters are temporarily pinned to exact commits in `Seigiard` forks for
runtime-directory support: [Pi #23][intercom-pi-dir],
[Claude #9][intercom-claude-dir], and [OpenCode #12][intercom-opencode-dir]. Core
remains pinned upstream. Once these changes land, replace the fork pins with
upstream commits containing the override and regenerate the lockfile.

Restart participating clients after deployment so they use the same directory.
This rollout starts with fresh state; the old `~/.pi/agent/intercom` manual-test
data is neither migrated nor deleted. Without the launcher or an explicit
override, upstream still uses its original Pi-relative default. Standalone
clients must receive the same `INTERCOM_DIR` to join the relocated broker.

[intercom-pi-dir]: https://github.com/dataforxyz/agent-intercom-pi/pull/23
[intercom-claude-dir]: https://github.com/dataforxyz/agent-intercom-claude/pull/9
[intercom-opencode-dir]: https://github.com/dataforxyz/agent-intercom-opencode/pull/12
