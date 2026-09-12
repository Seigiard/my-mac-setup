---
title: "Cold opencode and pi child launches fail with agent_prompt_stalled"
short_description: "Herdr's fixed three-second agent-start settle can report cold OpenCode or Pi as interactive before their input path is stable; herdr-child now adds a validated three-second pre-prompt grace for both kinds and retains its non-destructive stall recovery."
type: "bug"
category: "agent-platform"
tags: ["herdr-child","opencode","agent-startup","intermittent"]
date: "2026-09-03"
status: "done"
priority: "high"
closed: "2026-09-12"
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

## Resolution

Diagnosed the race against Herdr 0.9.0 and Pi 0.85.1: Herdr promotes a detected idle agent after a fixed three-second settle, while Pi can still route Enter through its startup handler, which retains text without submitting it. Added a validated, configurable three-second pre-prompt grace for every OpenCode and Pi child launch because Herdr exposes no cold/warm signal, rather than retrying an ambiguously delivered prompt; the existing stall path still preserves the pane. Added a semantic bashunit regression that fails with agent_prompt_stalled when the barrier is removed, exercises the shipped default for both affected kinds, and proves Claude remains undelayed. Verified with the focused red/green calibration, all 357 script tests (356 passed, one existing platform skip), make lint, and make test-local.
