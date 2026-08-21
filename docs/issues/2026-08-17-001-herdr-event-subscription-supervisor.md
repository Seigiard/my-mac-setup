---
title: "A supervisor process that subscribes to herdr agent-status events"
short_description: "A supervisor process that subscribes to herdr agent-status events"
type: "idea"
category: "herdr"
tags: ["herdr","idea"]
date: "2026-08-17"
status: "open"
priority: "medium"
parent-plan: "docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md"
---

## Why this exists

A parent agent that spawns a child in a sibling herdr pane loses track of it the moment its own turn ends. The child-agent launch contract closes the common case by having the child call the parent back — it submits text into the parent's pane, which starts a turn in the parent's session. That path depends entirely on the child's cooperation. A child that hangs, crashes, or ignores the instruction is not covered by it, and the plan records that gap as accepted.

herdr can close the remaining case, and the plan's original claim that it could not was wrong. `herdr api schema --json` describes a JSON-RPC-style socket protocol carrying `events.subscribe` and `events.wait`, and an event `pane_agent_status_changed` whose required fields are `type`, `pane_id`, `workspace_id`, and `agent_status`. The event fires on the child's pane regardless of what the child knows or does.

Two facts bound any design here:

- **A subscription lives only as long as the process holding the socket.** An agent turn cannot hold one across its own end, exactly as `herdr agent wait` cannot. Something must outlive the turn.
- **There is no CLI surface for it.** `herdr api` exposes only `snapshot` and `schema`. A subscriber has to speak the socket protocol directly.

The value is that supervision stops depending on the supervised party. Even with no new capability beyond what the launch contract already does, an external subscriber calling `herdr agent prompt` into the parent's pane is more reliable than the child doing it, because it still works when the child is the thing that broke.

## Scope

A long-lived subscriber that watches `pane_agent_status_changed` for a set of panes and wakes the interested parent by submitting text into its pane.

A shape worth exploring, which generalizes past a single parent-child pair into a supervision tree:

- Agent 1 starts agent 2.
- Agent 1 registers a subscription on agent 2's pane.
- Agent 2 starts agent 3.
- Agent 2 tells agent 1 that agent 3 exists.
- Agent 1 registers a subscription on agent 3's pane.

Concrete use cases for the tree are not established yet. The stability argument stands on its own and is reason enough to explore it.

This overlaps in spirit with the deleted `herdr-pair` skill, which also coordinated two agents — but `herdr-pair` ran its whole state machine inside one driver turn, which is the constraint this idea removes. Its transport is worth reading as prior art before designing a new one: the `[pair <from> -> <to> kind=<kind> sid=<sid>]` message header, and the cursor-authoritative read in `recv.sh` that exists because a stale header left in pane scrollback otherwise fires an early match. Both are recoverable from git history after the skill is deleted.

Out of scope: replacing the child-initiated return channel. The subscriber is a backstop for the case the child cannot cover, not a substitute for it.

## Open decisions

- Who starts the subscriber, and what keeps it running — a launchd agent, a herdr plugin, a pane the user can see, or a process the launch command starts on first use.
- What it does when the parent it should wake is gone, or is itself blocked on its own question.
- How a parent registers and deregisters interest in a pane, given the launch contract deliberately keeps no registry file.
- Whether one subscriber serves every parent on the machine or each parent runs its own, and how duplicates are avoided either way.
- Which statuses are worth waking on beyond `blocked`, and whether "no status change for N minutes" — the actual hang signal — is derivable from this event stream at all.
