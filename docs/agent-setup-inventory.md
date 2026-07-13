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
| crit              | `?` (crit CLI's skill — confirm)    | manual      |
| handoff           | `?` (likely `gh:mattpocock/skills`) | manual      |
| herdr             | `repo`                              | repo        |
| improve-claude-md | `gh:dexhorthy/slopfiles`            | chezmoi-ext |
| linear-cli        | `gh:schpet/linear-cli`              | chezmoi-ext |
| markdown-new      | `repo`                              | repo        |

Authored in repo but not currently applied live: `ask-agent`, `herdr-pair`
(see Drift).

### Agents (`~/.claude/agents/`)

| Agent                 | Source |
| --------------------- | ------ |
| open-source-librarian | `repo` |

---

## OpenCode

### Plugin (`~/.config/opencode/opencode.json` → `plugin[]`)

No OpenCode plugins are installed via `plugin[]`.

Local plugins kept in repo: `herdr-agent-state.js`, `rtk.ts`.

### Skills (`~/.config/opencode/skills/` — 39)

- `bundle:compound-engineering` — the `ce-*` set (37). Not enumerated.
- Own: `crit` (cross-tool), `lfg`.

### Agents (`~/.config/opencode/agent/` — ~51)

- `bundle:compound-engineering` — the `ce-*` reviewer/researcher set (~48). Not enumerated.
- Own / synced: `agent-enhancer`, `open-source-librarian`, `review`.

---

## Pi

### Packages (`~/.pi/agent/settings.json` → `packages[]`) — `pi install <source>`

| Package                 | Source                                           |
| ----------------------- | ------------------------------------------------ |
| pi-theme-flexoki        | `git:github.com/markacianfrani/pi-theme-flexoki` |
| pi-fff                  | `npm:@ff-labs/pi-fff`                            |
| pi-rtk                  | `npm:@sherif-fanous/pi-rtk`                      |
| pi-codex-conversion     | `npm:@howaboua/pi-codex-conversion`              |
| pi-agents               | `npm:pi-agents`                                  |
| pi-subagents            | `npm:pi-subagents`                               |
| pi-intercom             | `npm:pi-intercom`                                |
| pi-agent-browser-native | `npm:pi-agent-browser-native`                    |

### Skills (`~/.pi/agent/skills/`)

`crit` (cross-tool) · `web-research`

### Agents (`~/.pi/agent/agents/` — authored, keep)

`ask-claude` · `ask-external` · `ask-opencode` · `ask-pi` ·
`brainstorm-doc-reviewer` · `reviewer` · `se-plan-review` · `se-report-writer` ·
`synthes-agent`

---

## Codex / Gemini / Copilot

Ignored on purpose. `~/.codex/skills/` is now empty (`react-doctor`, `web-perf`
removed). Not reproduced by this repo.

---

## Cross-tool skills (want everywhere)

| Skill | Claude | OpenCode | Pi   | Source |
| ----- | ------ | -------- | ---- | ------ |
| crit  | ✓      | ✓        | ✓    | `?`    |
| herdr | ✓      | want     | want | `repo` |

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

- Source of `crit` and `handoff` unconfirmed (`manual` installs, not reproduced).
- Authored skills `ask-agent`, `herdr-pair` exist in the repo but are not applied
  to live `~/.claude/skills/` — confirm whether they should be.
- OpenCode carries `agent-enhancer`, `open-source-librarian`, `review` agents —
  confirm whether authored-and-synced or stragglers.
- Whether to make `herdr` multi-tool now (currently Claude-only live).
