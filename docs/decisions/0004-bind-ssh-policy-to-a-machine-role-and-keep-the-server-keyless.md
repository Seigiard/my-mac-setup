---
title: Bind SSH policy to a machine role and keep the server keyless
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0004: Bind SSH policy to a machine role and keep the server keyless

## Context

The repository configures three machines with different SSH responsibilities. A
server-held outbound private key would remain useful after a server compromise,
while independent per-machine configuration would let the intended access matrix
drift. The role model and its security trade-offs were introduced in commit
`232fec8` and specified in
`docs/plans/2026-09-09-0900-feat-role-based-ssh-access-plan.md`.

## Considered options

- Maintain independent SSH configuration on each machine.
- Provision a persistent outbound identity on the server.
- Persist one closed machine role and give the server temporary client identity
  through explicit agent forwarding.

## Decision

Chezmoi persists exactly one OS-compatible machine role and renders the committed
SSH topology from that role. Laptops use their own 1Password-backed identities.
The server stores no persistent outbound private key; attended outbound Git access
uses an explicit, non-multiplexed agent-forwarding session.

## Consequences

Adding a machine requires updating role validation, topology data, fixtures, and
rollout checks together. Agent forwarding exposes the client's whole agent to the
server for the attended session; that bounded risk is accepted instead of leaving
a reusable private key on the server.
