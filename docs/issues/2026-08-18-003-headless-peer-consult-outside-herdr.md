---
title: "Consulting a peer agent from outside herdr"
short_description: "Consulting a peer agent from outside herdr"
type: "follow-up"
category: "herdr"
tags: ["herdr","follow-up"]
date: "2026-08-18"
status: "open"
priority: "low"
parent-plan: "docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md"
---

## Why this exists

The peer-consult skill can be run from anywhere today. Inside herdr it opens a visible pane; outside herdr — a plain terminal, an editor, a scheduled run — it falls back to a headless subprocess and still returns an answer. That fallback is what the mode detection in `home/private_dot_claude/skills/ask-agent/scripts/ask.sh:58-70` is for.

The child agent launch contract deletes it. The plan's requirement R7 removes the headless mode and the three per-kind adapter scripts under `scripts/agents/`, and R28 renames the skill `ask-in-herdr` so the name stops promising something it no longer does. After that change, a consult outside herdr does not degrade — it refuses.

Two things drove the deletion, both recorded as a settled Key Decision in the plan. Two modes meant two mappings of the same four caller options — model, reasoning effort, extra skill directories, and opencode's configured agent — onto three agent CLIs, which is the kind of divergence the launch contract exists to end. And "read-only" meant two different things: enforceable without a pane, where the shell can be denied outright, and unenforceable with one, where the child needs a shell to call its parent back.

Losing the capability was accepted rather than overlooked. This file is where it is tracked.

## Scope

Give a caller outside herdr a way to consult a peer agent again, without reintroducing a second copy of the per-kind option mapping.

The shape named at decision time is a smithers wrapper: the harness already runs external claude and opencode legs as one-shot processes with timeouts, budget caps, and structured envelopes, in `~/.claude/.smithers/workflows/`. A consult is a smaller instance of what those legs already do, so the mapping work may be mostly done.

Open shapes worth comparing when this is picked up:

- A smithers workflow that takes an agent kind and a question and returns the answer, reusing the harness's existing per-leg invocation code.
- A `--headless` mode restored inside `ask-in-herdr`, sharing the launch command's option table rather than carrying its own — the launch command would need a mode that prints an agent's argv instead of starting it in a pane.
- No replacement: callers outside herdr use the agent CLIs directly.

Two constraints any shape has to satisfy. The per-kind option mapping and the two cross-model default models stay in one place — `openai-codex/gpt-5.5` for pi and `openai/gpt-5.5` for opencode are the reason a consult is a second opinion rather than the same model family agreeing with itself. And a headless consult has no return channel and needs none, so it can keep the stronger read-only posture that denies the shell outright; that posture is deleted along with the mode and is worth restoring rather than reinventing.

## Open decisions

- Whether a headless consult is needed at all, or whether every context that consults a peer already runs inside herdr.
- Whether the launch command grows an argv-printing mode so both paths share one option table, or whether the smithers wrapper carries its own.
- Whether the restored path keeps the shell-denying read-only posture, given that it has no callback to preserve.
