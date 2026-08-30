---
title: "herdr-child delivery can wake parent after reap invalidation"
short_description: "A reap invalidation that lands after deliver_supervision_event's initial check but before parent prompt can still deliver a stale lifecycle event, remove the run directory, and ignore the successful close transition."
type: "bug"
category: "herdr"
tags: ["herdr","race"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

Adversarial review of the 2026-08-30-001 reap-restore fix found a wider pre-existing TOCTOU window. `deliver_supervision_event` checks `invalidated.state` once before child and parent resolution. If reap writes its invalidation after that check, delivery can still prompt the parent and write a receipt after reap successfully closes the pane. The watcher then removes the run directory, while reap's best-effort `reap-closed` signal can fail because the directory is gone. The result is a spurious lifecycle wake for an explicitly reaped child.

## Scope

Serialize reap invalidation against event delivery at the final pre-prompt boundary. Evaluate a per-run transition guard shared by `begin_reap_invalidation` and `deliver_supervision_event`; preserve the current fail-closed reap behavior and avoid holding a filesystem lock across an unbounded external prompt. Add a barrier-driven semantic regression that lands invalidation after delivery's first state check and proves no parent prompt is sent.

## Open decisions

None.

## Resolution

Serialized reap invalidation with delivery's final prompt decision through a per-run transition guard and delivery claim. Reap now suppresses delivery when invalidation wins, fails closed without holding the guard across an active prompt when delivery wins, and reclaims claims owned by dead watchers. Added barrier-driven tests for all three orderings; calibrated the invalidation-first case red on the old implementation and verified focused tests, make lint, and make test-ubuntu.
