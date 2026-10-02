---
title: Centralize Intercom admission in the recovery engine
status: accepted
date: 2026-10-01
supersedes: []
---

# ADR-0022: Centralize Intercom admission in the recovery engine

## Context

Issues #389, #392, #393 and #394 addressed a split admission decision. The
launcher chose an enrollment route using Herdr CLI reads, while the recovery
engine fenced its own requests to a server incarnation. Existing-alias reuse
and Claude's pending-rename route also permit enrollment without a new claim.

## Considered options

- Keep route selection in the launcher and claim acquisition in the engine.
  This leaves one decision spread across callers with different read guarantees.
- Give the engine the enrollment decision while the launcher executes the client.
  This puts route selection and claim safety behind one interface.
- Let the engine refuse client startup when recovery is uncertain.
  This would change the native fallback accepted in ADR-0021.

## Decision

The recovery engine owns Intercom admission: enrollment route selection, alias
collision retries and claim safety. The launcher retains argument classification,
enrollment-component checks, environment export and client execution. Recovery
uncertainty produces native startup without enrollment, not a veto on startup.

The Herdr session adapter owns fenced requests, stable-terminal lookup and release
with observed readback. The engine owns recovery-intent transitions, retries and
archiving. A fake implements the adapter's observable contract, including uncertain
results, delayed application and server replacement. Explicit scheduling points
control event order. Real Herdr calibrates the fake; the fake adds no stronger
acquisition guarantee than Herdr provides.

One host dependency supplies process identity, ancestry and clock operations.
Recovery, the shell process helper and hook selfcheck share a documented
start-identity format. Process observation distinguishes alive with an identity,
confirmed exit and unknown evidence. Zombie state is separate from the start
token. Wall time and monotonic time remain separate operations.

Callers pass a recovery state root and, where needed, an opaque intent ID. Only
the engine derives intent, archive, lock and readiness paths. This rule concerns
recovery state paths, not socket or executable paths. The recovery root remains
distinct from the Intercom broker runtime.

This decision preserves the early reservation and independent cleanup guarantees
of ADR-0018 and ADR-0021. The interface migration is implemented under #402;
machine deployment follows the [stopped-client rollout](../intercom-recovery-rollout.md).
The agreed interface details are recorded in the
[interface design](../plans/2026-10-01-intercom-recovery-engine-interface.md).
