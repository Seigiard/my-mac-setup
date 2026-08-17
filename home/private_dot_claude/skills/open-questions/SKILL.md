---
name: open-questions
description: Walk every open decision one at a time, in prose — zero context, plain words, each option with its pros and cons and a recommendation.
disable-model-invocation: true
---

Stop the work. There are open decisions left. Ask them one at a time, in prose, in the language I wrote in.

First, before you write anything: list every open decision for yourself, drop the ones you can settle with a sensible default, and order the rest — what blocks the most work goes first. Do not show me that list; show me question one.

## One turn = one question

- Ask question one. End the turn. Wait for my answer.
- Open the turn with the position: `вопрос 1 из 4`. I need to know the runway.
- No AskUserQuestion menu. Prose only. A menu for this gets declined every time.
- No work, no edits, no tool calls in a question turn — the question is the whole turn.
- After my answer: if it changed what is still open, re-derive the list, then ask the next question. Restate the new count if it moved.
- If I say I did not understand, explain only. Re-ask that same question the turn after, rewritten — never a new question on top of an unanswered one.

## Shape of one question

Four parts, in this order:

1. **Что это** — the thing in plain words, for a reader who knows nothing about this session or this repo. Name it in full: what it is, where it lives (`path:line`), why it is on the table. Expand every acronym and every label you invented at first use.
2. **Что решаем** — the decision itself in one sentence, and what it blocks until I answer.
3. **Варианты** — 2–3 options. Each one gets its plus and its minus, spelled out as a consequence I will actually live with: what breaks, what it costs, what it locks in. Not adjectives, not "проще" without saying simpler for whom.
4. **Рекомендация** — one option, and the reason in one sentence.

## Words

- Zero context. No `как обсуждали`, no `тот файл`, no `вариант 2` from an earlier turn, no bare unit or ticket IDs. Name the thing again, every time, in full.
- Keep the exact technical term, the exact path, the exact command. Explain the term once; never swap it for an approximation.
- Short sentences, one idea each. Plain words around the technical ones.
- A risk, a caveat, or a precondition stays in the question even when the question is short.
