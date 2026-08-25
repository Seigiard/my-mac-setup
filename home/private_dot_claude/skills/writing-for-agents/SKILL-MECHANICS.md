# Skill mechanics

The skill-specific branch of [`writing-for-agents`](SKILL.md): what changes when the document is a skill — frontmatter, invocation, client packaging, and router skills. Everything else about writing it is the universal reference in `SKILL.md`.

## Choose invocation

Two choices trade the two loads:

- A **model-invoked** skill exposes its `description` as an always-loaded context pointer. The agent can load it when a trigger branch matches, another skill can direct the agent to it, and the human can still invoke it explicitly. Omit `disable-model-invocation` and write a model-facing description carrying the genuine trigger branches.
- An **explicit-only** skill keeps timing under human control. Its description becomes a short human-facing summary, and the client must hide it from model discovery while preserving manual invocation. This spends cognitive load instead of context load.

Pick model invocation only when the agent or another skill must reach the material without the human naming it. Shared reference needed by two explicit-only workflows belongs in a plain shared file, not inside either workflow.

## Package for each client

Keep one canonical body. Add a thin adapter only where a client cannot consume that body with the required invocation boundary.

### Claude Code

- Personal skills live at `~/.claude/skills/<name>/SKILL.md`; project skills live at `.claude/skills/<name>/SKILL.md`.
- `disable-model-invocation: true` creates an explicit-only skill that remains available as `/<name>`.
- Omit that field for model invocation. Claude Code uses `description` as the context pointer.
- Claude Code extensions such as `argument-hint`, invocation controls, tool controls, and forked context are not portable by default.

### OpenCode

- Global skills live at `~/.config/opencode/skills/<name>/SKILL.md`; project skills live at `.opencode/skills/<name>/SKILL.md`.
- OpenCode recognizes the Agent Skills fields `name`, `description`, `license`, `compatibility`, and `metadata`; it ignores unknown frontmatter fields. `disable-model-invocation` therefore does not create an explicit-only OpenCode skill.
- A discovered skill is model-visible through the `skill` tool. Use a native command adapter under `commands/` when a workflow must remain explicit-only.
- This setup disables automatic external and Claude-skill discovery with `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` and `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1`. Expose a model-invoked canonical Claude skill through a managed symlink under `home/private_dot_config/opencode/skills/`.

### Pi

- Global skills live at `~/.pi/agent/skills/`; project skills live at `.pi/skills/`.
- This setup adds `~/.claude/skills` to Pi's `settings.skills`, so Pi consumes the canonical Claude directory without another adapter.
- Pi honors `disable-model-invocation: true`: the skill leaves model discovery and remains manually available as `/skill:<name>` when skill commands are enabled.
- Pi ignores unknown frontmatter fields, but portable shared skills should keep client-only fields to those required by their canonical client.

## Own the managed source

Edit this repository's source under `home/`, never the deployed file under `~/`. Before adding a skill or adapter, check `home/.chezmoiexternal.toml` so an external and repository-managed source do not claim the same destination.

Use one canonical source:

- Author the shared body under `home/private_dot_claude/skills/<name>/` when Claude Code and Pi consume the same skill.
- Give OpenCode a symlink adapter for a model-invoked shared skill.
- Give OpenCode a command adapter for an explicit-only shared workflow.
- Record the client surfaces in `docs/agent-setup-inventory.md`.

## Split by invocation

Split off a model-invoked skill when a distinct leading word should trigger it on its own, or another skill must reach it. The independent reach must justify the new always-loaded description.

## Use router skills

When explicit-only workflows exceed what a human can remember, add one explicit-only **router skill** that names them and their trigger branches. The router reduces the human index to one entry; it does not make its targets model-invoked.

## File disclosed reference

Progressive disclosure decides *whether* material moves behind a pointer; reader count decides *where* it lives. Every session unconditionally → the always-loaded tier (`home/private_dot_claude/CLAUDE.md`, `home/private_dot_claude/rules/`). Two or more skills → `home/private_dot_claude/shared/`. Exactly one skill → that skill's own `references/`. A skill never points into another skill's `references/`. The filing rule and its one deliberate exception are in `home/private_dot_claude/shared/README.md`.

<!-- Source: https://github.com/mattpocock/skills/tree/main/skills/productivity/writing-for-agents — vendored alongside SKILL.md; the "Where the file goes in this setup" section is a local addition. -->
