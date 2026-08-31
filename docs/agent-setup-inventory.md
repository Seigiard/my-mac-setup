# Agent Setup Inventory

The repository reproduces the selected Claude Code, OpenCode, and Pi setup.
Codex, Gemini CLI, and GitHub Copilot are intentionally out of scope.

## Skill Ownership

`home/private_dot_config/agent-skills/manifest` is the source of truth for
selected upstream skills. `~/.local/bin/skills` installs them globally under
`~/.agents/skills`; its global lock owns those upstream children at
`${XDG_STATE_HOME}/skills/.skill-lock.json` when `XDG_STATE_HOME` is non-empty,
or `~/.agents/.skill-lock.json` otherwise.

`home/private_dot_agents/skills/` owns repository model-invocable skills.
Claude Code receives symlink adapters under `~/.claude/skills`; OpenCode and Pi
discover `~/.agents/skills` natively. No effective skill name may have both
owners.

| Ownership | Current inventory |
| --- | --- |
| Repository-owned | `ask-in-herdr`, `herdr`, `markdown-new`, `pf-build`, `pf-research`, `pf-spec`, `plan-explainer`, `se-cleanup`, `se-code-review`, `se-doc-review`, `se-flow`, `se-plan`, `se-review-and-work`, `se-simplify`, `se-work`, `vector-prime`, `work-summary`, `writing-for-agents` |
| Explicit-only | `eli5`, `open-questions`: Claude/Pi manual adapters and OpenCode command adapters only |
| Upstream-managed | Compound Engineering `*`; `linear-cli`; `improve-claude-md`; `architecture-designer`; `orca-cli`, `orchestration`; `find-skills`; `smithers`; `frontend-design`, `skill-creator`; `playground` |

`handoff` is absent and is not managed. `linear-cli`, not `linear`, is the
selected upstream skill name. `writing-for-agents` is a repository-owned local
fork and has no upstream update relationship.

## Skills CLI

Use `skills add <source> [skill...]`, `skills remove <source> <skill...>`,
`skills update [skill...]`, or `skills sync`. `sync` installs every manifest
entry and reports unmanaged or obsolete lock entries with explicit `skills
remove` commands. It never removes drift automatically. Restart Claude Code,
OpenCode, and Pi after installation or discovery configuration changes.

## Plugin-Owned Functionality

The Compound Engineering providers are retained only until
`~/.config/agent-skills/cutover-ready` exactly matches the managed generation;
then portable bare `ce-*` skills replace their client-specific providers.

Claude retains `claude-md-management`, `playwright`, `plugin-dev`,
`security-guidance`, and `typescript-lsp` for non-skill functionality. Its
Compound Engineering, `frontend-design`, and `playground` plugins are retired
after exact cutover. OpenCode retires its Compound Engineering plugin, including
its generated convenience commands, after exact cutover. Pi retires its
Compound Engineering package after exact cutover; its managed extension list
remains the source of truth for non-skill packages.

`open-source-librarian` is the repository-managed Claude agent. Smithers
workflows and local OpenCode support configuration remain repository-managed;
runtime state is not inventory.
