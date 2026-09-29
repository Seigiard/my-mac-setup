---
title: Recover Intercom launch claims without a successor
status: accepted
date: 2026-09-29
supersedes: []
---

# ADR-0021: Recover Intercom launch claims without a successor

## Context

ADR-0018 reserves a pane alias before starting a client. Its temporary lifecycle
claim can outlive a failed launch because `exec` removes the launcher's cleanup
trap. Reading client arguments reduces these failures but cannot predict startup
errors or exit before the first lifecycle report. Waiting for a later session to
repair the pane leaves status consumers without useful information meanwhile.

The owner approved automatic recovery in #377. The decision concerns launch
claims, not task supervision. It does not revive the supervisor rejected in
ADR-0019 or add another communication broker.

## Considered options

- Keep an argument classifier as the safety boundary and calibrate it against
  client releases. This cannot handle errors after parsing or an early exit.
- Keep early alias reservation and give each claim an independent cleanup owner.
  This preserves launch-time naming but requires safe cleanup across restarts.
- Register from client lifecycle callbacks. Pi exposes its resolved mode there;
  OpenCode needs pane-to-session attribution and Claude needs different startup
  wiring. This is a larger change to registration and readiness.

## Decision

Keep early alias reservation. Treat argument classification as a best-effort
utility bypass, not proof that a client will report back. A newly created launch
claim must have a cleanup owner that survives client replacement and can recover
after the launch exits without waiting for another session or prompt.

Cleanup may change only the exact launch claim it owns. It must preserve a newer
launch, a client that has taken over lifecycle reporting, and a live client that
has not received its first prompt. Record recovery intent before acquiring the
claim. If ownership cannot be established, start the client without a new claim
and report the loss of automatic enrollment.

This accepts the target behavior, not a completed implementation. ADR-0018 still
describes the deployed launch paths until the implementation passes the
[recovery specification](../plans/2026-09-29-intercom-claim-recovery-spec.md).
The first implementation gate must prove cleanup ownership and delayed-release
isolation on real Herdr before selecting the recovery process and enabling it.
If the current API cannot provide that isolation, stop at that gate and present
the required API change or the client-side alternative for a new decision.
