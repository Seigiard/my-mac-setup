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

### Compound Engineering Cutover

`~/.local/bin/skills` installs the Compound Engineering skills from the managed
manifest. Until `~/.config/agent-skills/cutover-ready` exactly matches the
managed `cutover-generation`, legacy providers remain enabled. This makes an
absent, stale, unreadable, or malformed marker a rollback-safe state.

| Client | Legacy provider | Non-skill inventory | Disposition after exact cutover |
| ------ | --------------- | ------------------- | ------------------------------ |
| Claude Code | `compound-engineering@compound-engineering-plugin` | Portable `ce-*` skills | Retire provider. No separately managed commands, agents, hooks, or extensions are required from it. |
| OpenCode | Compound Engineering plugin | Generated convenience commands for `ce-*` skills | Retire provider and commands. Native portable skill invocation is the accepted replacement. |
| Pi | `git:github.com/EveryInc/compound-engineering-plugin` package | Portable `ce-*` skills | Retire package. No separately managed commands, agents, hooks, or extensions are required from it. |

Claude's `frontend-design` and `playground` plugins are also retired only on
exact cutover because their selected skills move to the manifest. The retained
Claude plugins `claude-md-management`, `playwright`, `plugin-dev`,
`security-guidance`, and `typescript-lsp` provide non-skill behavior.

**Rollback:** remove `cutover-ready`, apply the retained-provider template
branch, and restart clients. Do not remove verified canonical skill trees.
Restoring the retired chezmoi external skill directories requires a git revert;
the marker does not restore their former ownership.

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

`compound-engineering-plugin` is a legacy marketplace declaration retained only
until exact cutover, then removed with its provider.

### Plugins — `claude plugin install <plugin>@<marketplace>`

| Plugin               | Marketplace             | Scope | Status                         |
| -------------------- | ----------------------- | ----- | ------------------------------ |
| claude-md-management | claude-plugins-official | user  | enabled                        |
| compound-engineering | compound-engineering-plugin | user | retained until exact cutover |
| frontend-design      | claude-plugins-official | user  | retained until exact cutover   |
| playground           | claude-plugins-official | user  | retained until exact cutover   |
| playwright           | claude-plugins-official | user  | enabled                        |
| plugin-dev           | claude-plugins-official | user  | enabled                        |
| security-guidance    | claude-plugins-official | user  | enabled                        |
| typescript-lsp       | claude-plugins-official | user  | enabled                        |

### Skills (`~/.claude/skills/`)

| Skill             | Source                              | Managed     |
| ----------------- | ----------------------------------- | ----------- |
| ask-in-herdr      | `repo`                              | repo        |
| eli5              | `repo`                              | repo        |
| handoff           | `?` (likely `gh:mattpocock/skills`) | manual      |
| herdr             | `repo`                              | repo        |
| improve-claude-md | managed manifest                    | Skills CLI  |
| linear            | managed manifest                    | Skills CLI  |
| markdown-new      | `repo`                              | repo        |
| open-questions    | `repo`                              | repo        |
| plan-explainer    | `repo`                              | repo        |
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

### Skills (`~/.config/opencode/skills/`)

- Own: `lfg`.
- Canonical Claude skills exposed through managed symlinks: `ask-in-herdr`,
  `markdown-new`, `plan-explainer`, all local `se-*` workflows (`se-cleanup`,
  `se-code-review`, `se-doc-review`, `se-flow`, `se-plan`,
  `se-review-and-work`, `se-simplify`, `se-work`), `vector-prime`,
  `work-summary`, `writing-for-agents`.

### Commands (`~/.config/opencode/commands/`)

| Command        | Source | Managed | Invocation |
| -------------- | ------ | ------- | ---------- |
| eli5           | `repo` | repo    | manual     |
| open-questions | `repo` | repo    | manual     |

### Agents (`~/.config/opencode/agent/` — ~51)

- Own / synced: `agent-enhancer`, `open-source-librarian`, `review`.

---

## Pi

### Packages (`~/.pi/agent/settings.json` → `packages[]`) — `pi install <source>`

`home/dot_pi/agent/modify_settings.json` is the source of truth for Pi package
extensions. Its `extensions` array is an exact desired list: `chezmoi apply`
writes it to `~/.pi/agent/settings.json` `packages[]`. No Pi package extension
is manual, and this inventory intentionally does not duplicate the package list.

### Skills (`~/.pi/agent/skills/`)

Pi has no explicit Claude skill-root discovery source after cutover. Portable
skills are discovered from the global Skills CLI installation instead.

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
