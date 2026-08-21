---
title: pi-subagentura adopted unpinned although the trial premise was a pinned version
type: follow-up
date: 2026-08-21
status: done
closed: 2026-08-21
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

## Resolution

Pinned to `npm:pi-subagentura@3.3.0` — the trialed version is also the version the host actually runs, so no re-trial was needed. Evidence: `~/.pi/agent/npm/node_modules/pi-subagentura/package.json` reports `"version": "3.3.0"`, and `pi list` shows the package installed from that path.

What was done:

- `home/dot_pi/agent/modify_settings.json` — the required entry is now `npm:pi-subagentura@3.3.0`, and the modifier replaces a stale unpinned (or differently pinned) `npm:pi-subagentura` entry instead of accumulating a duplicate alongside it.
- `tests/scripts.bats` — the modifier test now feeds a stale unpinned entry and asserts it is replaced by the pinned one; the idempotence test uses the pinned entry.
- `tests/smoke.bats` — asserts the applied `~/.pi/agent/settings.json` carries the pinned entry and not the unpinned one. This test stays red on the host until the next `chezmoi apply`; CI applies the checkout first and passes.
- `docs/plans/2026-08-18-1819-pi-subagentura-trial-plan.html` — Phase 4 decision record added: "Trial passed — adopted at npm:pi-subagentura@3.3.0".
