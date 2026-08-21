---
title: Pi skills and agents in the inventory doc do not match disk
type: follow-up
date: 2026-08-21
status: open
---

## Why this exists

The Pi packages audit (issue `2026-08-19-001-pi-package-inventory-drift`)
reconciled the packages table in `docs/agent-setup-inventory.md`, but the two
neighboring Pi subsections also drifted and were out of that audit's scope:

- **Skills**: the doc lists `web-research` under `~/.pi/agent/skills/`. On disk
  that directory contains only `smithers`; `web-research` is gone.
- **Agents**: the doc lists nine authored agents (`ask-claude`, `ask-external`,
  `ask-opencode`, `ask-pi`, `brainstorm-doc-reviewer`, `reviewer`,
  `se-plan-review`, `se-report-writer`, `synthes-agent`) as "authored, keep"
  under `~/.pi/agent/agents/`. That directory does not exist, and none of the
  nine are tracked anywhere in this repo (`rg` finds them only in the inventory
  doc itself).

The agents were marked "keep", so the doc entry may be the only remaining record
of them — removing the lines without a decision could lose that intent.

## Scope

Decide per subsection: resurrect the content (recover the agents from Pi
session history or another machine, then track them in `home/dot_pi/agent/`),
or accept the loss and update `docs/agent-setup-inventory.md` to the actual
state (`smithers` skill; no agents directory).

## Open decisions

- Are the nine authored Pi agents still wanted, and does a copy survive
  anywhere recoverable?
- Is the `smithers` skill worth listing (and managing) in the inventory?
