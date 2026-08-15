---
title: The work block's planPath prompt got prose back, not the return-to-caller envelope
type: bug
date: 2026-08-15
status: done
closed: 2026-08-15
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

## Resolution

The envelope is stated in the prompt; `makeWorkAgent`'s `jsonSchema` is untouched.

- `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts` — a shared `ENVELOPE_CONTRACT` string is appended to every agent block's prompt: `work` (both branches), `repro`, `analysis`, `subtasks`. It asks for exactly one JSON object `{"report": "<envelope serialized as a JSON string>"}`, names the envelope's fields, and states the two conditions `envelopeComplete` adds on top of parsing — `status="complete"` and a non-empty `verification_evidence`. The field list is `Object.keys(workEnvelopeSchema.shape)`, read off the schema at module load rather than hand-copied, so the prompt that asks and the parser that judges cannot drift apart.
- Tests: `workflows/lib/blocks/index.test.ts` asserts, per agent block, that the prompt names every field of `workEnvelopeSchema` (the list comes from the schema, so a new field fails the test until the prompt is regenerated) and that it asks for the `{"report": …}` wrapper explicitly.

**Open decision — prompt or schema.** Prompt. The `{report: string}` wrapper is deliberate and its reason is recorded in `docs/issues/2026-08-14-004`: a raw output shape turns a malformed model response into an `INVALID_OUTPUT` task failure, so a crashed leg skips work that should still happen, where the wrapper keeps a bad response parseable into an explicit red row. Tightening `jsonSchema` would trade a readable red row for a dead task.

**Open decision — whether `se-pipeline` has the same gap.** It does not. `workPrompt` (`workflows/se-pipeline.tsx:242`) already ends with `Your FINAL message must be EXACTLY one JSON object and nothing else: {"report": "<the skill's return-to-caller envelope (status, plan_path, changed_files, u_ids_attempted, u_ids_completed, verification_results, verification_evidence, blockers, behavior_change, standalone_shipping_skipped) serialized as a string>"}`. That list matches `workEnvelopeSchema` exactly, minus `final_commit_sha`, which the schema marks optional and documents as a pipeline extension. The gap was flow-only, and the fix ports the pipeline's wording into the block library.

Proven by unit tests only. No live `se flow` run was made — editing the interpreter's module graph is forbidden while a run is live or parked (KTD1), so a live re-verification is the operator's call.
