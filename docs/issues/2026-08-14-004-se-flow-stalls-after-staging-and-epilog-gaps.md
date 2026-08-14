---
title: se flow epilog is partial — no artifact archive, no publication scan, stub reviewer, four features absent
type: bug
date: 2026-08-14
status: in-progress
parent-plan: docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md
---

# se flow epilog is partial, and four features the checklist assumes are absent

## Why this exists

Host verification section 4 could not be executed. Attempting it surfaced two blockers and four absent features. Sections 2 and 3 of `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` were blocked on the same set.

Both blockers are now fixed and `se flow` runs end to end. What remains open is the epilog and the four absent features, recorded below.

### The interpreter had never run at all

`se flow` rejected every launch at workflow construction:

```
code: INVALID_INPUT
Output schema for "outcome" uses reserved field name(s): runId.
```

smithers reserves `runId`, `nodeId` and `iteration` as internal columns on every persisted node output. `se-flow.tsx` declared `outcome.runId`, so the engine refused the workflow before any node ran. Fixed in `de81825` by renaming the field to `flowRunId`.

Worth noting for anything else built this way: `bun build` cannot catch this class of error. It resolves the module graph without type-checking and never instantiates the workflow, so a green build says nothing about whether a run can start. Every claim of "the interpreter is structurally complete, its module graph resolves" rested on exactly that check.

### It stalled after staging — FIXED in `56801e1`

`run-1786702018234` reached `waiting-event` right after `staging`, rendered no block, wrote no `block_output` row, and did not advance on resume. `error_json` was empty.

The cause was neither of the two leads first recorded here. The smithers engine arms proof verification on the **presence** of a Task's `bind` prop, not its value — `@smithers-orchestrator/graph`'s `extract.js` tests `Object.hasOwn(raw, "bind")`, and its own comment says to "omit the prop entirely". `se-flow.tsx` passed `bind={undefined}` for every block with no `bindTo` edges. That armed verification with zero proofs, parking the node as `waiting-bound` and the run as `waiting-event`, permanently and silently.

`smithers why <runId>` names it in one line and should be the first command run against any `waiting-event` park: *"The Task declared `bind={undefined}`; produce the authority row, then resume the run."*

Two further findings from the same fix, both now closed:

- `ctx.prove` returns `undefined` for a row that does not exist yet (`driver/src/SmithersCtx.js:392`), so binding to a not-yet-produced block was the same trap. Blocks are now withheld from the render until every `bindTo` target has a durable row.
- A block whose task threw records its verdict under the guard's `-crashed` node. No reader knew about that node, so a crashed block looked un-run forever and the epilog would never render.

The `Each child in a list should have a unique "key" prop` warning is unrelated and benign — `se-pipeline.tsx` emits it too and has always run correctly.

Verified by execution: `run-1786703798413`, a three-block compute spec chained by `bindTo`, finished with all blocks and the full epilog. It is the first `se flow` run to complete end to end.

### Four features the checklist assumes, which are not written

- **`se flow salvage <runId>`** (U5, KTD10). Zero occurrences of `salvage` in `bin/executable_se`. Section 4.2 tests it.
- **Budget-ceiling parking** (KTD9). `budgetUsd` reaches `makeAgent` as a per-agent cap, and a `budget` output key is declared, but there is no budget compute task and no park branch anywhere in `se-flow.tsx`. A breach cannot park a run because nothing measures it. Section 4.3 tests it.
- **`artifactsFrom` delivery** (R9). The validator checks the archive exists (`flow-validate.ts:175`) and normalisation carries the field, but no code reads a prior run's manifest or hands artifacts to any block. The handoff is validated and never performed. Section 4.4 tests it.
- **Artifact archiving** (KTD10). The epilog creates `$TMPDIR/se-flow/<runId>/` and writes `outcome.json` into it, then copies nothing. The `proof-artifacts` manifest is never read. The directory is an archive in name only.

### Two more epilog gaps

- **No publication-time secret scan** (KTD13b). The epilog writes the outcome record with a plain `fs.writeFileSync`. Nothing scans the record, the issue text, or a PR body before it is written or pushed.
- **The terminal reviewer is a stub** (R14, R15, U6). The `reviewer` epilog node is a deterministic compute task calling `classifyDisposition`; it is not the agent block the plan specifies, and `issue-writer.ts` is never called from anywhere in `se-flow.tsx`. No run can produce a `docs/issues/` file. Section 3's entire pass criterion is that an injected failure yields one, so section 3 cannot pass until this exists.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the epilog, the missing budget node, the missing artifact copy, the missing secret scan, the stub reviewer.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — `se flow salvage`.
- `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` — section 3 stays unrunnable until the reviewer writes an issue file. Section 4 stays unrunnable for its salvage, budget and `artifactsFrom` scenarios; scenario 4.1 (hard-kill and resume) became runnable once the stall was fixed.

## Open decisions

- **Whether the reviewer stays a compute classifier or becomes the agent block** the plan specifies. The compute version cannot write a cause analysis, which is what R15 asks for; the agent version costs a leg on every run, including clean ones.
- **Whether a build-time check can catch reserved-field and schema errors** so the next one is not found by a failed launch. A test that merely imports and instantiates the workflow would have caught the reserved-field one. It would not have caught the `bind={undefined}` park, which only appears once a node is scheduled — that class still needs a live compute-only smoke run.
