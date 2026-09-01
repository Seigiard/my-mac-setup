# Agent Setup Inventory

The repository reproduces the selected Claude Code, OpenCode, and Pi setup.
Codex, Gemini CLI, and GitHub Copilot are intentionally out of scope.

## Skill Ownership

`home/private_dot_config/agent-skills/manifest` is the source of truth for
selected upstream skills. `~/.local/bin/skills` installs them globally under
`~/.agents/skills`; its global lock owns those upstream children at
`${XDG_STATE_HOME:-$HOME/.local/state}/skills/.skill-lock.json`.

`home/private_dot_agents/skills/` owns repository model-invocable skills.
Claude Code receives symlink adapters under `~/.claude/skills`; OpenCode and Pi
discover `~/.agents/skills` natively. No effective skill name may have both
owners.

| Ownership | Current inventory |
| --- | --- |
| Repository-owned | `ask-in-herdr`, `herdr`, `markdown-new`, `pf-build`, `pf-research`, `pf-spec`, `plan-explainer`, `se-cleanup`, `se-code-review`, `se-doc-review`, `se-plan`, `se-simplify`, `vector-prime`, `work-summary`, `writing-for-agents` |
| Explicit-only | `eli5`, `open-questions`: Claude/Pi manual adapters and OpenCode command adapters only |
| Upstream-managed | Compound Engineering `*`; `linear-cli`; `improve-claude-md`; `orca-cli`, `orchestration`; `find-skills`; `frontend-design`, `skill-creator` |

`handoff` is absent and is not managed. `linear-cli`, not `linear`, is the
selected upstream skill name. `writing-for-agents` is a repository-owned local
fork and has no upstream update relationship.

## Skills CLI

Use `skills add <source> [skill...]`, `skills remove <source> <skill...>`,
`skills update [skill...]`, or `skills sync`. `sync` installs every manifest
entry and reports unmanaged or obsolete lock entries with explicit `skills
remove` commands. It never removes drift automatically. Restart Claude Code,
OpenCode, and Pi after installation or discovery configuration changes.
Successful upstream CLI output is hidden by default; use `skills --verbose
<command>` to restore it. Failed commands always replay the captured diagnostics.

## Plugin-Owned Functionality

Portable bare `ce-*` skills replace the former client-specific Compound
Engineering providers.

Claude retains `claude-md-management`, `playwright`, `plugin-dev`,
`security-guidance`, and `typescript-lsp` for non-skill functionality. Its
Compound Engineering and `frontend-design` plugins are retired. OpenCode does
not install the Compound Engineering plugin or its generated convenience
commands. Pi does not install the Compound Engineering package; its managed
extension list remains the source of truth for non-skill packages.

`open-source-librarian` is the repository-managed Claude agent.
