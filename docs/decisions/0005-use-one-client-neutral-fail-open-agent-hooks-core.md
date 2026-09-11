---
title: Use one client-neutral, fail-open agent-hooks core
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0005: Use one client-neutral, fail-open agent-hooks core

## Context

Claude Code, OpenCode, and Pi expose different hook transports and outcome
capabilities, but they need the same repository-owned policies. Separate policy
implementations had already drifted. The shared design and its rejected
alternatives are recorded in
`docs/plans/2026-09-03-0833-feat-agent-hooks-core-plan.md` and shipped in commit
`e2f7bd5`.

## Considered options

- Keep one hand-written policy implementation per client.
- Introduce a larger runtime that negotiates capabilities dynamically.
- Put policy in one client-neutral core with thin transport adapters and a static
  client registry.

## Decision

One Bun/TypeScript core owns policy normalization and ordered dispatch. Thin
client adapters translate transport events and outcomes. A static registry owns
client-specific tool names and capabilities, and applicability is derived from
that registry. Import, normalization, dispatch, and policy-exception failures all
fail open.

## Consequences

Policy is written once, but a broken optional guard cannot stop all tool use. The
accepted cost is that a failure can silently remove protection. OpenCode
subagent calls bypass hooks, Claude and Pi subagent coverage is not established,
and input-dependent policy exceptions have no durable log. Resident sessions can
also keep an older policy version until restart. Tests must exercise each route
the registry claims to support without implying coverage beyond those bounds.
