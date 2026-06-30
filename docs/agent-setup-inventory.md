# Agent setup inventory

Created: 2026-06-26

The curated list of agent skills / agents / plugins I actually **choose**, for
manual reinstall across Claude Code, OpenCode, and Pi. Bundle internals (skills
and agents that ship inside a plugin/extension) are **not** listed individually —
they come back when the bundle is installed. Maintained by hand; install
manually. No scripts, templates, or tests.

Ignored on purpose: Codex / Gemini CLI / GitHub Copilot targets.

Source legend:

- `gh:<owner/repo>` GitHub
- `npm:<pkg>` npm
- `git:<url>` git
- `repo` authored in this dotfiles repo
- `bundle:<name>` provided by a bundle
- `?` source unconfirmed — fill in.

---

## Cross-tool skills (my own / want everywhere)

| Skill        | Tools                               | Source                                        |
| ------------ | ----------------------------------- | --------------------------------------------- |
| crit  | Claude, OpenCode, Pi                | `?` (crit tool's skill — confirm)             |
| herdr | Claude → **want OpenCode + Pi too** | `repo` (home/private_dot_claude/skills/herdr) |

---

## Claude Code

### Marketplaces (add first: `claude plugin marketplace add <source>`)

| Marketplace                 | Source                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------ |
| claude-plugins-official     | `gh:anthropics/claude-plugins-official`                                              |
| cc-marketplace              | `gh:kenryu42/cc-marketplace`                                                         |
| impeccable                  | `gh:pbakaus/impeccable`                                                              |
| compound-engineering-plugin | `gh:EveryInc/compound-engineering-plugin`                                            |
| obsidian-skills             | `git:git@github.com:kepano/obsidian-skills.git` (only used project-scope — optional) |

### Plugins (user-scope, global: `claude plugin install <name>@<marketplace>`)

**claude-plugins-official:** playwright · playground · claude-md-management · plugin-dev

**cc-marketplace:** safety-net
**impeccable:** impeccable
**compound-engineering-plugin:** compound-engineering

### Authored skills (`home/private_dot_claude/skills/` — already in repo)

ask-agent · herdr · herdr-pair · markdown-new

### Skills pulled from upstream (`home/.chezmoiexternal.toml` — already in repo)

| Skill             | Source                                             |
| ----------------- | -------------------------------------------------- |
| rigorous-coding   | `gh:jarrodwatts/claude-code-config`                |
| linear-cli        | `gh:schpet/linear-cli`                             |
| improve-claude-md | `gh:dexhorthy/slopfiles`                           |
| handoff           | `?` (present in ~/.claude/skills — confirm source) |

### Authored agents (`home/private_dot_claude/agents/` — already in repo)

open-source-librarian

---

## OpenCode

### Plugins (`~/.config/opencode/opencode.json` → `plugin[]`; OpenCode self-installs at startup)

| Plugin           | Source                                                                                                                     |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------- |
| @rynfar/meridian | `gh:rynfar/meridian` (`npm:@rynfar/meridian`) — install the package and reference it (replaces the old absolute brew path) |

### Local plugins (files, keep in repo)

herdr-agent-state.js · rtk.ts

### Skills / agents

Mostly `bundle:oh-my-openagent` (the ce-\* set + reviewer agents) — do not hand-list.
Cross-tool own skills here: crit, herdr (wanted). Also web-perf, lfg.

---

## Pi

### Extensions (`~/.pi/agent/settings.json` → `packages[]`; `pi install <source>`)

| Extension               | Source                                                                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| pi-theme-flexoki        | `git:github.com/markacianfrani/pi-theme-flexoki`                                                                                        |
| pi-fff                  | `npm:@ff-labs/pi-fff`                                                                                                                   |
| pi-rtk                  | `npm:@sherif-fanous/pi-rtk`                                                                                                             |
| pi-codex-conversion     | `npm:@howaboua/pi-codex-conversion`                                                                                                     |
| pi-agents               | `npm:pi-agents`                                                                                                                         |
| pi-subagents            | `npm:pi-subagents`                                                                                                                      |
| pi-intercom             | `npm:pi-intercom`                                                                                                                       |
| pi-agent-browser-native | `npm:pi-agent-browser-native` (https://pi.dev/packages/pi-agent-browser-native — replaced the old local absolute path / coctostan repo) |

### Skills / agents

Skills: crit, web-perf, web-research.
Agents (`~/.pi/agent/agents/`, hand-authored — keep): ask-claude · ask-external ·
ask-opencode · ask-pi · brainstorm-doc-reviewer · reviewer · se-plan-review ·
se-report-writer · synthes-agent.

---

## Excluded / cleaned up

- **Codex / Gemini / Copilot** targets (e.g. `web-perf` in `~/.codex/skills/`) — ignored.
- **Claude project-scope plugins** (not global): frontend-design, feature-dev,
  security-guidance, code-simplifier, typescript-lsp (all @ `Projects/platform`),
  obsidian (@ Dropbox Knowledge Base).
- **Pi compound-engineering orphan** — deleted 2026-06-26 (was an uncoordinated
  install: 49 agent files + a private manifest, never in `packages[]`).

---

## Manual install quickref

- **Claude:** `claude plugin marketplace add <source>` then
  `claude plugin install <name>@<marketplace>`. Authored + upstream skills come
  via `chezmoi apply` (already managed).
- **OpenCode:** ensure entries in `~/.config/opencode/opencode.json` `plugin[]`;
  install the meridian package; OpenCode self-installs npm plugins at startup.
- **Pi:** `pi install <source>` for each `packages[]` entry (`pi list` to check,
  `pi update --all` to refresh).

## To confirm

- Sources marked `?`: crit, handoff.
- Whether to make herdr multi-tool now (currently Claude-only).
