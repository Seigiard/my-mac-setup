---
title: Use one delivery owner per supervision generation
status: rejected
date: 2026-09-18
supersedes: []
---

# ADR-0019: Use one delivery owner per supervision generation

> **Cancelled as premature.** The user withdrew the durable-supervisor effort
> after reviewing its incremental value over resource-tree context and existing
> watchers. This document preserves the considered design, not an implementation
> mandate. The existing watcher is not being replaced. See the updated
> [planning map](https://github.com/Seigiard/my-mac-setup/issues/285).

## Context

The existing detached child watcher observes lifecycle state, sends parent
prompts, and records delivery receipts. Adding a crash-resilient supervisor as
an independent backstop would create two delivery owners. Serialization inside
either process alone cannot prevent both from confirming the same wake.

The user chose replacement rather than a concurrent backstop while resolving
[Choose observer topology and duplicate-delivery semantics](https://github.com/Seigiard/my-mac-setup/issues/290).
This was an accepted design for the deferred supervisor before the effort was
cancelled; it never became deployed behavior.

## Considered options

- Keep the watcher as primary and add a backstop. This requires shared receipts,
  exclusive delivery claims, and a takeover protocol that fences a stalled old
  owner before a new one sends anything.
- Replace the watcher for new generations and let existing generations drain.
  Each generation has one backend and one receipt authority; migration does not
  claim recovery for generations created under the old ephemeral contract.

## Decision

Do not build the durable supervisor at this stage. Resource-tree context and
the existing watcher meet the current need; the incremental crash-recovery
service has no demonstrated need that justifies its additional lifecycle and
delivery machinery. Reconsideration requires a new explicit decision.

### Archived design

The durable supervisor is the sole delivery owner for generations admitted by
the new managed launch path. Existing watcher-owned generations remain with
their watcher until completion or explicit invalidation. There is no automatic
fallback, adoption, or live takeover of a legacy generation.

An accepted managed continuation can create a supervisor-owned generation only
after the old generation's delivery path is fenced. If that cannot be proven,
the operation reports uncertainty rather than submitting another prompt or
starting a second delivery owner. The supervisor's durable store owns receipts
for its generations; legacy receipts are not silently imported.

Detailed registration, deadline, turn-attribution, and recovery semantics remain
in the linked decision ticket. Herdr remains authoritative for placement, and
the resource tree remains provenance storage rather than a task-state database.
