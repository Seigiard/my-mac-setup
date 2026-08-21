---
title: Pi package inventory does not match current managed settings
type: follow-up
date: 2026-08-19
status: done
closed: 2026-08-21
---

## Why this exists

`docs/agent-setup-inventory.md` lists several manually managed Pi packages, including `npm:@ff-labs/pi-fff`.

The current `~/.pi/agent/settings.json` and `pi list` output contain only the compound engineering plugin, `pi-ask-user`, and `pi-subagentura`. The documented manual package inventory therefore does not describe the reproducible or current Pi setup.

## Scope

Decide which documented Pi packages remain useful. Add selected packages to `home/dot_pi/agent/modify_settings.json`, add smoke coverage, and update `docs/agent-setup-inventory.md`. Remove obsolete entries from the inventory.

## Open decisions

- Whether any older manual Pi packages should remain in the inventory.

## Progress

Chezmoi now manages `pi-web-access`, `pi-context-view`, and `npm:@ff-labs/pi-fff`. The broader manual-package inventory audit remains open.

## Resolution

Audit completed 2026-08-21 against three states: `pi list`, the live
`~/.pi/agent/settings.json`, and the managed set in
`home/dot_pi/agent/modify_settings.json`. All three agree exactly — every
installed package is chezmoi-managed, so `modify_settings.json` and the smoke
tests needed no change; only the doc did.

| Package (doc entry)         | Verdict          | Evidence                                                              |
| --------------------------- | ---------------- | --------------------------------------------------------------------- |
| compound-engineering-plugin | keep, managed    | in `pi list`, settings.json, modify_settings.json                     |
| pi-web-access               | keep, managed    | same three                                                            |
| pi-context-view             | keep, managed    | same three                                                            |
| pi-fff (`@ff-labs`)         | keep, managed    | same three                                                            |
| pi-ask-user                 | keep, managed    | same three                                                            |
| pi-subagentura              | keep, managed    | same three (pinning question stays with issue 2026-08-21-017)         |
| pi-loop (`@trevonistrevon`) | keep, managed    | same three                                                            |
| pi-theme-flexoki            | removed from doc | not in `pi list`; `~/.pi/agent/git/github.com/` has only `EveryInc`   |
| pi-codex-conversion         | removed from doc | `@howaboua` absent from `~/.pi/agent/npm/node_modules/`               |
| pi-agents                   | removed from doc | absent from node_modules                                              |
| pi-subagents                | removed from doc | absent from node_modules (superseded in practice by `pi-subagentura`) |
| pi-intercom                 | removed from doc | absent from node_modules                                              |
| pi-agent-browser-native     | removed from doc | absent from node_modules                                              |

Doc change: the Pi packages table in `docs/agent-setup-inventory.md` now lists
the seven managed packages, all `repo`, with a note that
`home/dot_pi/agent/modify_settings.json` enforces the set. No package stays
consciously manual — the six `manual` rows described packages that are not
installed anywhere.

Side finding filed separately: the doc's Pi Skills and Agents subsections also
drifted (skill `web-research` gone, `~/.pi/agent/agents/` gone) — see issue
`2026-08-21-020-pi-skills-and-agents-inventory-drift`.
