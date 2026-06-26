# Agent setup inventory

Created: 2026-06-26

The curated list of agent skills / agents / plugins I actually **choose**, for
manual reinstall across Claude Code, OpenCode, and Pi. Bundle internals (skills
and agents that ship inside a plugin/extension) are **not** listed individually —
they come back when the bundle is installed. Maintained by hand; install
manually. No scripts, templates, or tests.

Ignored on purpose: Codex / Gemini CLI / GitHub Copilot targets.

Source legend: `gh:<owner/repo>` GitHub · `npm:<pkg>` npm · `git:<url>` git ·
`repo` authored in this dotfiles repo · `bundle:<name>` provided by a bundle ·
`?` source unconfirmed — fill in.

---

## Cross-tool skills (my own / want everywhere)

| Skill | Tools | Source |
|---|---|---|
| crit | Claude, OpenCode, Pi | `?` (crit tool's skill — confirm) |
| herdr | Claude → **want OpenCode + Pi too** | `repo` (home/private_dot_claude/skills/herdr) |
| react-doctor | Claude, OpenCode | `gh:millionco/react-doctor` |

---

## Claude Code

### Marketplaces (add first: `claude plugin marketplace add <source>`)

| Marketplace | Source |
|---|---|
| claude-plugins-official | `gh:anthropics/claude-plugins-official` |
| claude-code-workflows | `gh:wshobson/agents` |
| cc-marketplace | `gh:kenryu42/cc-marketplace` |
| context7-marketplace | `gh:upstash/context7` |
| impeccable | `gh:pbakaus/impeccable` |
| chrome-devtools-plugins | `gh:ChromeDevTools/chrome-devtools-mcp` |
| compound-engineering-plugin | `gh:EveryInc/compound-engineering-plugin` |
| obsidian-skills | `git:git@github.com:kepano/obsidian-skills.git` (only used project-scope — optional) |

### Plugins (user-scope, global: `claude plugin install <name>@<marketplace>`)

**claude-plugins-official:** code-review · playwright · pr-review-toolkit ·
explanatory-output-style · learning-output-style · hookify · superpowers ·
playground · claude-md-management · plugin-dev · chrome-devtools-mcp

**claude-code-workflows:** code-documentation · debugging-toolkit · unit-testing ·
code-refactoring · javascript-typescript · c4-architecture ·
frontend-mobile-development · conductor · accessibility-compliance

**cc-marketplace:** safety-net
**context7-marketplace:** context7-plugin
**impeccable:** impeccable
**compound-engineering-plugin:** compound-engineering
**chrome-devtools-plugins:** chrome-devtools-mcp

> ⚠️ `chrome-devtools-mcp` is installed from **both** claude-plugins-official and
> chrome-devtools-plugins — pick one source to avoid a duplicate.

### Authored skills (`home/private_dot_claude/skills/` — already in repo)

ask-agent · herdr · markdown-new · react-doctor · review-plan · tdd-integration

### Skills pulled from upstream (`home/.chezmoiexternal.toml` — already in repo)

| Skill | Source |
|---|---|
| react-best-practices | `gh:vercel-labs/agent-skills` |
| composition-patterns | `gh:vercel-labs/agent-skills` |
| react-useeffect | `gh:jarrodwatts/claude-code-config` |
| rigorous-coding | `gh:jarrodwatts/claude-code-config` |
| linear-cli | `gh:schpet/linear-cli` |
| ast-grep | `gh:ast-grep/agent-skill` |
| improve-claude-md | `gh:dexhorthy/slopfiles` |
| handoff | `?` (present in ~/.claude/skills — confirm source) |

### Authored agents (`home/private_dot_claude/agents/` — already in repo)

agent-enhancer · open-source-librarian · plan-architect · plan-pragmatist ·
plan-skeptic · plan-synthesizer · tdd-implementer · tdd-refactorer · tdd-test-writer

---

## OpenCode

### Plugins (`~/.config/opencode/opencode.json` → `plugin[]`; OpenCode self-installs at startup)

| Plugin | Source |
|---|---|
| oh-my-openagent | `npm:oh-my-openagent` — **bundle**: provides ce-* skills + ~49 agents |
| @rynfar/meridian | `gh:rynfar/meridian` (`npm:@rynfar/meridian`) — install the package and reference it (replaces the old absolute brew path) |

### Local plugins (files, keep in repo)

herdr-agent-state.js · rtk.ts

### Skills / agents

Mostly `bundle:oh-my-openagent` (the ce-* set + reviewer agents) — do not hand-list.
Cross-tool own skills here: crit, react-doctor, herdr (wanted). Also web-perf, lfg.

---

## Pi

### Extensions (`~/.pi/agent/settings.json` → `packages[]`; `pi install <source>`)

| Extension | Source |
|---|---|
| pi-theme-flexoki | `git:github.com/markacianfrani/pi-theme-flexoki` |
| pi-fff | `npm:@ff-labs/pi-fff` |
| pi-rtk | `npm:@sherif-fanous/pi-rtk` |
| pi-codex-conversion | `npm:@howaboua/pi-codex-conversion` |
| pi-agents | `npm:pi-agents` |
| pi-subagents | `npm:pi-subagents` |
| pi-intercom | `npm:pi-intercom` |
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
- Drop the duplicate `chrome-devtools-mcp` marketplace source.
