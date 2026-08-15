---
title: The work block's planPath prompt got prose back, not the return-to-caller envelope
type: bug
date: 2026-08-15
status: open
parent-plan: docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md
---

# The work block's planPath prompt got prose back, not the return-to-caller envelope

## Why this exists

On `run-1786777192782` the `work` block gated red with a correct code change underneath it. The block's `planPath` branch builds this prompt (`home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts:215`):

```ts
return i.planPath ? `Execute the plan at ${i.planPath} headless via ce-work mode:return-to-caller.` : `Implement headless: ${i.prompt ?? ""}`;
```

The agent implemented the plan correctly and returned a prose summary in its `report` field:

> Plan docs/plans/fixture-slugify-bug-plan.md executed. Implemented U1 (lowercase the slug) … Verification: `bun test` is green — 3 pass, 0 fail …

`parseWorkEnvelope` (`lib/envelopes.ts:27`) requires `report` to be a JSON string matching `workEnvelopeSchema`, so it refused with "envelope does not parse as JSON" and `envelopeComplete` reddened the block. The work itself was fine: the next block committed a changed tree and `run-validate` recorded `exitCode 0` on the same commit.

The prompt names `ce-work mode:return-to-caller` and nothing makes the agent load that skill or emit its envelope. The agent's `jsonSchema` constrains only the wrapper (`{report: string}`, `agents.ts:267`), not the string's contents, so a well-behaved agent that answers in prose passes the schema and fails the gate.

Rerunning the same spec with the block's other branch — `input.prompt` spelling the envelope keys out inline — produced a valid envelope and a green block on `run-1786777410571`. So the failure is in what the `planPath` prompt asks for, not in the model's ability to answer.

This is adjacent to `docs/issues/2026-08-15-002-se-flow-work-block-hands-the-agent-a-launcher-plan-path.md` — the same one-line `buildPrompt` — but a separate failure: that issue is about *where* the path points, this one is about the response shape the prompt does not pin down. Both are cheap to fix in the same place.

Worth knowing: a red gate here did not stop the run, so the flow published a PR anyway. That is tracked separately in `docs/issues/2026-08-15-003-a-red-block-does-not-stop-the-se-flow-run.md`.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts` — the `work` block's `buildPrompt`, both branches. `repro`, `analysis` and `subtasks` share `implementationAgent` and the same `envelopeComplete` gate, so their prompts have the same hole.
- `home/private_dot_claude/dot_smithers/workflows/lib/agents.ts` — `makeWorkAgent`'s `jsonSchema` is where a tighter output contract could be enforced instead of asked for.
- `home/private_dot_claude/dot_smithers/workflows/lib/envelopes.ts` — `workEnvelopeSchema` is the shape any prompt fix has to state.

## Open decisions

- **Whether to state the envelope in the prompt or enforce it in the schema.** Spelling the keys out in `buildPrompt` is a one-line change and matches what worked on the retry; making `jsonSchema` describe the envelope directly would make a prose answer impossible rather than merely discouraged, but it changes the `{report: string}` wrapper that `docs/issues/2026-08-14-004` records as deliberate — a raw shape turns a malformed response into an `INVALID_OUTPUT` task failure instead of a parseable red row.
- **Whether `se-pipeline` has the same gap.** It reaches ce-work through its own stage rather than through this block, and it has not been observed failing this way; confirming that before changing the shared gate would say whether this is flow-only.
