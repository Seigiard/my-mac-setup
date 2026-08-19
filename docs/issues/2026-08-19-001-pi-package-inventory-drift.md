---
title: Pi package inventory does not match current managed settings
type: follow-up
date: 2026-08-19
status: open
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
