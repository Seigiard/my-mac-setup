---
title: "Harden child-agent ownership and launch cleanup"
short_description: "Harden child-agent ownership and launch cleanup"
type: "follow-up"
category: "agent-platform"
tags: ["agent-platform","follow-up"]
date: "2026-08-18"
status: "open"
priority: "medium"
parent-plan: "docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md"
---

## Why this exists

External code review run `ed66a73a-3e84-4f35-b99e-c95f3eaa8d77` identified residual risks after the child-agent launch contract was implemented.

`home/dot_local/bin/executable_herdr-child` validates a supplied child name and pane against the live herdr agent list. It does not persist a parent-owned launch record. A parent can therefore target an unrelated live agent if it supplies that agent's matching name and pane. The current contract requires the caller to retain coordinates and check them, but the command does not enforce ownership itself.

A successful `herdr pane split` can also leave an orphaned pane if the split response is malformed or lacks `result.pane.pane_id`. The command cannot close a pane whose identifier it could not recover.

The review also found lower-priority duplication. `ask-in-herdr/scripts/ask.sh` derives unique names before `herdr-child start`, while `herdr-child` separately rejects live-name collisions. `json_has_name` and `json_has_pair` are near-duplicate JSON predicates in `executable_herdr-child`.

The review's suggestion that a child can bypass the parent-command guard by unsetting `HERDR_CHILD_PARENT_PANE` is not an authentication defect. Environment variables and message markers are coordination data, not a security boundary. A future ownership mechanism must not treat them as credentials.

## Scope

- Define a parent-scoped launch record or opaque launch token returned by `herdr-child start`.
- Require `reply` and `reap` to prove that the target belongs to the current parent.
- Keep ownership records correct when panes close, names are reused, or herdr restarts.
- Make split cleanup recover the new pane ID independently of the response, or change the herdr API so malformed success responses cannot orphan panes.
- Consolidate child-name allocation in one layer.
- Consolidate the JSON agent predicates without changing behavior.
- Add fake-herdr and live tests for cross-parent rejection, stale records, name reuse, and malformed split responses.

## Open decisions

- Should ownership state live in a parent-local file, herdr pane metadata, or a herdr-native child relationship?
- Should `reply` and `reap` accept an opaque token, or should they resolve ownership from the current parent pane and persisted records?
- What cleanup rule removes ownership records after a crash without allowing a stale record to target a reused name or pane?
- What herdr primitive can identify a newly split pane if the command response cannot be parsed?
