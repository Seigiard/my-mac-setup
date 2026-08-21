---
title: pi-subagentura adopted unpinned although the trial premise was a pinned version
type: follow-up
date: 2026-08-21
status: open
---

## Why this exists

The trial plan `docs/plans/2026-08-18-1819-pi-subagentura-trial-plan.html` gated adoption on a pinned package: `npm:pi-subagentura@3.3.0`. The adoption commit `4cbae5e` shipped an unpinned entry instead: `home/dot_pi/agent/modify_settings.json:25` reads `"npm:pi-subagentura"` with no version. Any `pi` package refresh can silently move the machine to an untried version, which is exactly what the trial design was meant to prevent.

The plan also never received its Phase 4 decision record ("Trial passed / failed / inconclusive") — the outcome is only inferable from the adoption commit.

Found during the 2026-08-21 audit of `docs/plans/`. Related: [2026-08-19-001](2026-08-19-001-pi-package-inventory-drift.md) covers the broader pi package inventory drift; this issue is only about the missing version pin.

## Scope

- Pin the entry in `home/dot_pi/agent/modify_settings.json` to the trialed version (or a newer deliberately chosen one).
- Update the matching assertions in `tests/smoke.bats:321` and `tests/scripts.bats` if they match on the unpinned string.
- Optionally add a one-line decision record to the trial plan.

## Open decisions

- Pin to `3.3.0` (the trialed version) or re-trial the current latest and pin that.
