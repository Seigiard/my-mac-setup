---
title: "Cold opencode and pi child launches fail with agent_prompt_stalled"
short_description: "A cold first-of-session opencode or pi child reproducibly fails `herdr-child start` with `agent_prompt_stalled`: herdr's 5000 ms first-state-change window elapses before the agent accepts input, while all warm launches of both kinds and cold claude succeed (2 of 2 cold non-claude stalled, 0 of 8 warm), and the stall path additionally destroys the pane so the transcript is lost."
type: "bug"
category: "agent-platform"
tags: ["herdr-child","opencode","agent-startup","intermittent"]
date: "2026-09-03"
status: "open"
priority: "high"
---

## Why this exists

The first opencode or pi child launched in a session reproducibly fails `herdr-child start`
on herdr 0.8.2:

```
{"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed
state change within 5000 ms; status is idle and state_change_seq remained 2149"},
"id":"cli:agent:prompt"}
herdr-child: initial prompt stalled
```

`agent start` returns `"interactive_ready":true` first, so herdr believes the pane is ready.
`start_child` then sends the initial prompt immediately, and for a cold opencode or pi the
agent has not yet reached the point where it reacts to input. The 5000 ms first-state-change
window elapses and the launch is treated as fatal.

This is the launch path behind the `ask-in-herdr` skill, so it also carries the OpenCode leg
of `se-code-review`, `se-doc-review`, and `se-plan`. The practical effect is that the first
cross-model consult of any session fails, and the second succeeds. The failure is loud
(exit 1 plus error JSON), so it degrades review coverage rather than corrupting a result.

Two properties make each occurrence hard to diagnose:

1. `home/dot_local/lib/herdr-child-launch.sh:522-529` treats a stalled initial prompt as
   fatal in `wait` mode: it prints the message, calls `cleanup_pane prompt-failure`, and
   returns 1. The pane is destroyed, so the transcript that would show what the agent was
   doing during those 5000 ms is gone before anyone can read it.
2. The `agent start` retry loop above it matches only `agent_pane_busy`. There is no retry
   for a stalled first prompt.

## Scope

Decide whether the initial prompt should retry on `agent_prompt_stalled`, wait longer before
prompting a kind known to be slow, or verify readiness by a signal stronger than
`interactive_ready`. Regardless of that choice, preserve diagnosability: a stalled initial
prompt should capture the child transcript, or keep the pane, before cleanup.

Measurements on 2026-09-03, herdr 0.8.2, same repository checkout:

| Kind | State | Runs | Stalls |
|---|---|---:|---:|
| claude | cold (first of session) | 1 | 0 |
| opencode | cold (first of session) | 1 | **1** |
| opencode | warm | 7 | 0 |
| pi | cold (first of session) | 1 | **1** |
| pi | warm | 1 | 0 |

Every cold non-claude launch stalled; every warm launch succeeded. The warm opencode set
includes three runs launched concurrently with a claude child, so concurrency is not the
trigger.

Hypotheses eliminated:

- Not concurrency. Three concurrent claude+opencode pairs all succeeded.
- Not prompt length or an absolute file path in the prompt. A manually started OpenCode
  given the identical file-reading prompt completed it in 15.8 s.
- Not an agent crash. A manually started OpenCode stayed alive and idle throughout, and its
  pane showed all five MCP servers connected.
- Not claude-specific tooling. Cold claude succeeded; the two kinds that stall are the two
  that are slower to become responsive.

Remaining unknown: what exactly consumes the cold-start time. OpenCode connects five MCP
servers (deepwiki, executor, fff, jina, tavily-mcp) during startup, which is a plausible
cost, but this was not instrumented and pi's cold path was not inspected at all.

## Open decisions

- Whether the fix belongs in `herdr-child` (retry, or a longer pre-prompt wait for kinds
  known to start slowly) or should be reported upstream to the agent CLIs.
- Whether a stalled initial prompt should keep the pane open by default, or capture a
  transcript into the run directory and then clean up as it does today.
