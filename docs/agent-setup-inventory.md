# Agent setup inventory

The curated list of plugins / skills / agents I **choose**, for manual reinstall
across Claude Code, OpenCode, and Pi. Maintained by hand. Bundle internals
(skills/agents that ship inside a plugin or distribution) are listed as **one
line**, never enumerated — they come back when the bundle is installed.

Codex / Gemini CLI / GitHub Copilot targets are ignored on purpose.

**Source:** `gh:owner/repo` · `npm:pkg` · `git:url` · `repo` (authored in this
dotfiles repo) · `bundle:name` (ships inside a bundle) · `?` (unconfirmed).
**Managed:** `chezmoi-ext` (`home/.chezmoiexternal.toml`) · `repo` (tracked here)
· `manual` (installed by hand / a CLI, not reproduced by this repo).

## Common

### Compound Engineering

Install on Claude, Opencode, Pi

https://github.com/EveryInc/compound-engineering-plugin

### CC Safety Net

Install on Claude, Opencode, Pi

https://ccsafetynet.com/docs/installation

---

## Claude Code

### Marketplaces — `claude plugin marketplace add <source>`

| Marketplace             | Source                                  |
| ----------------------- | --------------------------------------- |
| claude-plugins-official | `gh:anthropics/claude-plugins-official` |
| cc-marketplace          | `gh:kenryu42/cc-marketplace`            |

### Plugins — `claude plugin install <plugin>@<marketplace>`

| Plugin               | Marketplace             | Scope | Status  |
| -------------------- | ----------------------- | ----- | ------- |
| claude-md-management | claude-plugins-official | user  | enabled |
| playground           | claude-plugins-official | user  | enabled |
| playwright           | claude-plugins-official | user  | enabled |
| skill-creator        | claude-plugins-official | user  | enabled |
| plugin-dev           | claude-plugins-official | user  | enabled |

### Skills (`~/.claude/skills/`)

| Skill             | Source                              | Managed     |
| ----------------- | ----------------------------------- | ----------- |
| ask-in-herdr      | `repo`                              | repo        |
| eli5              | `repo`                              | repo        |
| handoff           | `?` (likely `gh:mattpocock/skills`) | manual      |
| herdr             | `repo`                              | repo        |
| improve-claude-md | `gh:dexhorthy/slopfiles`            | chezmoi-ext |
| linear            | `gh:schpet/linear-cli`              | chezmoi-ext |
| markdown-new      | `repo`                              | repo        |
| open-questions    | `repo`                              | repo        |
| se-code-review    | `repo` (local CE wrapper)           | repo        |
| se-doc-review     | `repo` (local CE wrapper)           | repo        |
| se-plan           | `repo` (local CE wrapper)           | repo        |
| writing-for-agents | `repo` (vendored from `gh:mattpocock/skills`) | repo |


### Smithers workflows (`~/.claude/.smithers/`)

| Workflow       | Source | Managed |
| -------------- | ------ | ------- |
| se-code-review | `repo` | repo    |
| se-doc-review  | `repo` | repo    |

Managed Smithers backends remain available to `se-pipeline` and `se-flow`; standalone review wrappers launch fresh Herdr peers. Runtime deps/state are ignored.

### Agents (`~/.claude/agents/`)

| Agent                 | Source |
| --------------------- | ------ |
| open-source-librarian | `repo` |

---

## OpenCode

### Plugin (`~/.config/opencode/opencode.json` → `plugin[]`)

No OpenCode plugins are installed via `plugin[]`.

Local plugins kept in repo: `herdr-agent-state.js`.

### Skills (`~/.config/opencode/skills/` — 38)

- `bundle:compound-engineering` — the `ce-*` set (37). Not enumerated.
- Own: `lfg`.

### Commands (`~/.config/opencode/commands/`)

| Command        | Source | Managed | Invocation |
| -------------- | ------ | ------- | ---------- |
| eli5           | `repo` | repo    | manual     |
| open-questions | `repo` | repo    | manual     |

### Agents (`~/.config/opencode/agent/` — ~51)

- `bundle:compound-engineering` — the `ce-*` reviewer/researcher set (~48). Not enumerated.
- Own / synced: `agent-enhancer`, `open-source-librarian`, `review`.

---

## Pi

### Packages (`~/.pi/agent/settings.json` → `packages[]`) — `pi install <source>`

`home/dot_pi/agent/modify_settings.json` is the source of truth for Pi package
extensions. Its `extensions` array is an exact desired list: `chezmoi apply`
writes it to `~/.pi/agent/settings.json` `packages[]`. No Pi package extension
is manual, and this inventory intentionally does not duplicate the package list.

### Skills (`~/.pi/agent/skills/`)

No Pi-only live skills are kept. Pi reads shared Claude skills from
`~/.claude/skills` through `~/.pi/agent/settings.json` `skills[]`.
This includes the explicit-only `eli5` and `open-questions` skills, invoked as
`/skill:eli5` and `/skill:open-questions`.

### Agents (`~/.pi/agent/agents/`)

No live Pi agents are kept. Add any future agent to `home/dot_pi/agent/agents/`
before using it, so `chezmoi apply` can reproduce it.

---

## Codex / Gemini / Copilot

Ignored on purpose; not reproduced by this repo.

---

## Cross-tool skills (want everywhere)

| Skill | Claude | OpenCode | Pi   | Source |
| ----- | ------ | -------- | ---- | ------ |
| herdr | ✓      | want     | want | `repo` |

## Explicit-only workflows

`eli5` and `open-questions` share canonical descriptions and bodies from
`home/.chezmoitemplates/explicit-only-<name>-*`. Claude Code adapters keep
`disable-model-invocation: true`; Pi consumes those Claude skills; OpenCode
receives manual command adapters and no native skill adapters.

When adding or updating one of these workflows:

1. Change its canonical description and body under `home/.chezmoitemplates/`.
2. Add or update the Claude `SKILL.md.tmpl` and OpenCode command `.md.tmpl` thin adapters.
3. Keep `$ARGUMENTS`, `$<digits>`, and unquoted `@path` out of canonical bodies unless OpenCode expansion is intentional.
4. Keep both `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` and `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` in `home/dot_zshenv.tmpl`.
5. Extend the focused explicit-only case in `tests/smoke.bats`, run the Docker verification, apply through the normal chezmoi source-clone workflow, and restart each client from managed zsh.

Verified behavior baselines are OpenCode `1.18.20` and Pi `0.84.2`. If an
observed client version differs, rerun the manual discovery and invocation
checks before updating these baseline versions.

---

## Install quickref

- **Claude:** `claude plugin marketplace add <source>`, then
  `claude plugin install <plugin>@<marketplace>`. Skills marked `chezmoi-ext` /
  `repo` come via `chezmoi apply`; `manual` ones must be reinstalled by hand.
- **OpenCode:** ensure `plugin[]` in `opencode.json` if plugins are added;
  OpenCode self-installs npm plugins at startup.
- **Pi:** `pi install <source>` per `packages[]` (`pi list` to check,
  `pi update --all` to refresh).

## Drift / to confirm

- Source of `handoff` is unconfirmed (`manual` install, not reproduced).
- OpenCode carries `agent-enhancer`, `open-source-librarian`, `review` agents —
  confirm whether authored-and-synced or stragglers.
- Whether to make `herdr` multi-tool now (currently Claude-only live).
