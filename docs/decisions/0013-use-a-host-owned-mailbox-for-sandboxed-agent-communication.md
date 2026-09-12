---
title: Use a host-owned mailbox for sandboxed agent communication
status: accepted
date: 2026-09-12
supersedes: []
---

# ADR-0013: Use a host-owned mailbox for sandboxed agent communication

## Context

The child-agent contract currently carries decisions through `herdr-child
ask/reply`. A child invokes host-side Herdr control to wake its parent, so a
sandbox must either expose that control surface or break the mandatory return
channel. Exposing it gives the child more authority than message delivery
requires and makes a narrow filesystem or process boundary harder to reason
about.

The project separately tracks what a child may do inside its worktree and what
it can reach outside one in
`docs/issues/2026-08-18-001-launch-time-permission-mode-for-child-agents.md` and
`docs/issues/2026-08-18-002-sandbox-a-child-agents-filesystem-access.md`. Agent
communication crosses both boundaries: it must remain available inside a
sandbox without becoming a route to arbitrary host control.

## Considered options

- Keep direct `herdr-child ask/reply` and grant each sandbox access to the Herdr
  control surface.
- Add a mailbox while permanently retaining direct callbacks as a second
  communication path.
- Put a mailbox broker outside the sandbox and make it the sole agent-to-agent
  communication boundary.
- Adopt a specific MCP mailbox product before fixing the transport contract.

## Decision

Use a host-owned mailbox broker as the target communication boundary for
agents. The broker persists a message before delivery, authenticates its sender,
authorizes its recipient from the launch relationship graph, and asks a
host-side Herdr adapter to wake an idle recipient. Only that adapter may access
Herdr control. A sandboxed agent receives a capability for the mailbox, not the
Herdr CLI or control socket.

Message authority is typed and role-bound. Questions and peer messages are data;
only an authorized parent task or reply may direct a child to continue work. The
broker transports and authorizes messages but never executes their contents.

The first implementation slice replaces only parent-child `ask/reply`. Direct
callbacks remain during migration and are removed after mailbox delivery,
wake-up, retry, and cleanup reach behavioral parity. Sibling communication,
file reservations, attachments, task orchestration, and cross-project delivery
are deferred.

This decision does not select a mailbox product or sandbox runtime. An existing
MCP mailbox may back the contract if a trial proves the required identity,
authorization, delivery, and containment properties. Launch-time permission
rules remain an inner policy layer; the sandbox remains the boundary on what a
process can actually reach.

## Consequences

VM and container sandboxes no longer need a general bridge to host-side Herdr
control, but the mailbox broker becomes security- and lifecycle-critical.
Delivery can repeat across retries or wake-up recovery, so consumers must handle
duplicate messages without repeating the represented decision or action.
Implementation and verification are tracked in
`docs/issues/2026-09-12-002-replace-child-ask-reply-with-a-sandbox-safe-mailbox.md`.
