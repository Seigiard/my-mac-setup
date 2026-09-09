---
title: "A supervisor process that subscribes to herdr agent-status events"
short_description: "Per-child detached watchers now cover ordinary lifecycle wakes; retain this issue for crash/restart resilience, socket-event supervision, and recovery beyond one watcher process."
type: "idea"
category: "herdr"
tags: ["herdr","idea"]
date: "2026-08-17"
status: "open"
priority: "low"
parent-plan: "docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md"
---

## Why this exists

A parent agent cannot supervise a child from inside a turn that has already ended. The managed detached contract now closes the ordinary case with an external per-child watcher: it polls fresh lifecycle state, emits timeout and later-settlement wakes, detects unplanned pane disappearance, and falls back when a child cannot call `herdr-child ask`.

The watcher is intentionally process-local and ephemeral. It does not survive its own crash, a machine restart, or loss of its owner-only run directory. Its short-TTL `supervised` label makes that loss honest, but no replacement process reconstructs supervision. This issue now tracks that residual durability gap rather than the already-implemented per-child lifecycle path.

herdr can close the remaining case, and the plan's original claim that it could not was wrong. `herdr api schema --json` describes a JSON-RPC-style socket protocol carrying `events.subscribe` and `events.wait`, and an event `pane_agent_status_changed` whose required fields are `type`, `pane_id`, `workspace_id`, and `agent_status`. The event fires on the child's pane regardless of what the child knows or does.

Two facts bound any design here:

- **A subscription lives only as long as the process holding the socket.** An agent turn cannot hold one across its own end, exactly as `herdr agent wait` cannot. Something must outlive the turn.
- **There is no CLI surface for it.** `herdr api` exposes only `snapshot` and `schema`. A subscriber has to speak the socket protocol directly.

The remaining value is restartable supervision that does not depend on one watcher process. A socket subscriber could reconstruct interest after crashes, deduplicate against generation-and-event receipts, and observe status transitions without per-child polling.

## Scope

A long-lived subscriber that watches `pane_agent_status_changed` for registered detached generations, reconstructs supervision after watcher or machine restart, and wakes the identity-matched parent without duplicating already confirmed generation-and-event delivery.

A shape worth exploring, which generalizes past a single parent-child pair into a supervision tree:

- Agent 1 starts agent 2.
- Agent 1 registers a subscription on agent 2's pane.
- Agent 2 starts agent 3.
- Agent 2 tells agent 1 that agent 3 exists.
- Agent 1 registers a subscription on agent 3's pane.

Concrete use cases for the tree are not established yet. The stability argument stands on its own and is reason enough to explore it.

This overlaps in spirit with the deleted `herdr-pair` skill, which also coordinated two agents — but `herdr-pair` ran its whole state machine inside one driver turn, which is the constraint this idea removes. Its transport is worth reading as prior art before designing a new one: the `[pair <from> -> <to> kind=<kind> sid=<sid>]` message header, and the cursor-authoritative read in `recv.sh` that exists because a stale header left in pane scrollback otherwise fires an early match. Both are recoverable from git history after the skill is deleted.

Out of scope: replacing `herdr-child ask`, the current per-child watcher, or attached `--wait`. The subscriber is a crash-resilient backstop, not a second ordinary lifecycle implementation.

## Open decisions

- Who starts the subscriber, and what keeps it running — a launchd agent, a herdr plugin, a pane the user can see, or a process the launch command starts on first use.
- What it does when the parent it should wake is gone, or is itself blocked on its own question.
- How a parent registers and deregisters generation-scoped interest without turning ephemeral watcher state into a stale machine-wide ownership registry.
- Whether one subscriber serves every parent on the machine or each parent runs its own, and how duplicates are avoided either way.
- How subscriber delivery interoperates with the current timeout-then-settlement semantics and confirmed generation-and-event receipts.

## Upstream surface measured (2026-09-06)

Checked against the installed herdr rather than taken from the record: `herdr --version` reports
0.8.2, `herdr api --help` lists exactly two subcommands, `snapshot` and `schema`, and
`herdr api schema --json` does contain all three of `events.subscribe`, `events.wait` and
`pane_agent_status_changed`. Both halves of this record's framing therefore still hold — the socket
protocol carries the events, and no CLI surface exposes them, so a subscriber has to speak the
protocol directly.

That leaves the item's cost where the record already put it: something must outlive an agent turn to
hold the subscription, which means a long-lived daemon with its own install, restart and
crash-recovery story. This is a feature to design, not a defect to fix, and the record itself states
that concrete use cases for the supervision tree are not yet established. Whether that daemon is
wanted at all is the decision this needs.

## Decision (2026-09-06): accepted, deferred

Build it — but not now. This is accepted work rather than an open question, so the five items under
Open decisions above are design work waiting for a start date, not gates on whether to start at all.

What that changes for a future reader: do not re-litigate whether the daemon is wanted. Do measure
before building. The gap it closes is a crash-only tail — a watcher process dying, a machine
restarting, an owner-only run directory lost mid-flight — whose frequency nobody has observed, while
the per-child watcher covers every ordinary wake today. The cheapest way to earn that evidence is to
make the short-TTL `supervised` label's expiry surface a visible "supervision lost" signal, turning
an unmeasured tail into an observed one. That cost was not measured either and should be before it
is treated as the small step it appears to be.
