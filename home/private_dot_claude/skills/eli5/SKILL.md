---
name: eli5
description: Re-explain the last message from zero context — plain words, no session labels, one question at a time.
disable-model-invocation: true
---

Stop. Your last message did not land. Re-explain it for a reader with zero context: they know nothing about this session, this repo, or any label you invented along the way.

- Plain words, short sentences. Keep the exact technical terms, but explain each one at first use.
- No session-local labels: no `area 1`, no `U3`, no `option 2`, no bare ticket or PR numbers. Name the thing itself; an ID goes in parentheses at most.
- Start from what the thing IS and why it matters. Only then say what happened or what you claim.
- If the message asked for a decision, restate it as a decision brief: the thing in plain words, what exactly is being decided, 2-3 options each with its consequence, your recommendation.
- If the message held several questions, take only the first one. Ask the next after I answer.
- Explanation only this turn: no question menu, no new work, no tool calls.
