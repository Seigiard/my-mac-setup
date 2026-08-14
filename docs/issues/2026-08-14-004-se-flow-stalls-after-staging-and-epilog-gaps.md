---
title: se flow is missing salvage, artifactsFrom delivery, and a secret scan of the PR body
type: bug
date: 2026-08-14
status: in-progress
parent-plan: docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md
---

# se flow is missing salvage, artifactsFrom delivery, and a secret scan of the PR body

## Why this exists

Host verification section 4 could not be executed. Attempting it surfaced two blockers and four absent features. Sections 2 and 3 of `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` were blocked on the same set.

Both blockers are fixed, `se flow` runs end to end, and sections 3, 4.3 and 6 of the checklist now pass. What remains open is the three items below.

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

### Three features the checklist assumes, which are not written

- **`se flow salvage <runId>`** (U5, KTD10). Zero occurrences of `salvage` in `bin/executable_se`. Section 4.2 tests it.
- **`artifactsFrom` delivery** (R9). The validator checks the archive exists (`flow-validate.ts:175`) and normalisation carries the field, but no code reads a prior run's manifest or hands artifacts to any block. The handoff is validated and never performed. Section 4.4 tests it.
- **No publication-time secret scan of a PR body** (KTD13b). The outcome record and the issue text are both redacted before writing. The PR body is not, and the `pr` block is the only `publishes: true` block in the catalog.

### Budget parking, the cost figure and `se resume` — FIXED in `b87d803`

Spend is measured after every block; a breach parks the run for an ack and withholds the remaining blocks. The outcome record carries tokens and a priced estimate. Two defects surfaced on the way and are fixed in the same commit:

- `budgetUsd` was passed both as the run ceiling and as each agent's hard cap. Those point opposite ways — the ceiling is a parking threshold KTD9 says must never kill, the cap is a kill — so every leg hard-killed at exactly the point KTD9 says to park, and a run with no `--budget` capped agents at `$0`. The per-agent cap now derives from the block's cost profile.
- `se resume` was hardcoded to `se-pipeline.tsx`, so every parked flow run was unrecoverable. It routes on the run's recorded `workflow_path` now.

Known limit: the record's cost excludes the epilog reviewer leg, which runs after the record is written. Writing the record first is the deliberate choice — it survives a reviewer that hangs to its timeout.

### Artifact archiving and the record scan — FIXED in `00c375e`

The epilog now copies every manifest file into `<archive>/artifacts/` before cleanup deletes the worktree, and redacts the outcome record before writing it. Verified live: `run-1786705191733` (archive survives the worktree) and `run-1786705276045` (planted `ghp_` token absent from the record).

### The terminal reviewer was a stub — FIXED in `cae6a61`

The `reviewer` epilog node was a deterministic compute task that only restated block statuses, and `issue-writer.ts` was called from nowhere. It is now an epilog-slot agent leg that returns a cause analysis, with a deterministic task rendering and writing the `docs/issues/` file. The agent never writes the file, so KTD13 redaction stays enforced by code.

Two structural rules came out of the first live run and are worth keeping in mind for any other agent leg in an epilog:

- The verdict rides inside the `{report: string}` wrapper, not as the agent's raw output shape. A raw shape turns a malformed model response into an `INVALID_OUTPUT` task failure rather than a parseable no-verdict row.
- Work that must happen even when an agent leg dies belongs OUTSIDE that leg's `TryCatchFinally`. Issue writing was originally inside the try branch, so it was skipped exactly when the reviewer died — on runs that most owe the operator an issue.

Section 3 of the host checklist now passes; see its Results entry.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — `artifactsFrom` delivery, the PR-body scan.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — `se flow salvage`.
- `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` — sections 3 and 6 now pass. Scenarios 4.2 (salvage) and 4.4 (`artifactsFrom`) stay unrunnable; 4.1 (hard-kill and resume) became runnable once the stall was fixed, and 4.3 (budget parking) now passes.

## Open decisions

- **What the reviewer leg should cost.** Settled for now as sonnet with a $3 ceiling, because it runs on every flow including clean ones; observed legs took 30-45s. Revisit if a large flow's reviewer starts approaching the cap.
- **Whether a build-time check can catch reserved-field and schema errors** so the next one is not found by a failed launch. A test that merely imports and instantiates the workflow would have caught the reserved-field one. It would not have caught the `bind={undefined}` park, which only appears once a node is scheduled — that class still needs a live compute-only smoke run.
