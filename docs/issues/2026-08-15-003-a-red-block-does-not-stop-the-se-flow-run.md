---
title: "A red block does not stop the se-flow run — its successors run, including pr"
short_description: "A red block does not stop the se-flow run — its successors run, including pr"
type: "bug"
category: "se-pipeline"
tags: ["se-pipeline","bug"]
date: "2026-08-15"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md"
closed: "2026-08-15"
---

# A red block does not stop the se-flow run

## Why this exists

Observed live on `run-1786777192782` while executing section 2 of the host verification checklist. The `fix` block (`work`, `waive: "none"`) gated **red**. The five blocks after it — `commit-work`, `run-validate`, `proof-artifacts`, `secret-scan`, and `pr` — all dispatched anyway, the run reached status `finished`, and the `pr` block pushed a branch and opened a real pull request on the target remote:

```
fix       | work            | failed
commit    | commit-work     | green
validate  | run-validate    | green
artifacts | proof-artifacts | green
scan      | secret-scan     | green
open-pr   | pr              | green   → .../pull/1  {"result":"opened"}
```

The published PR body carries the red row, so the state is visible after the fact — but publication is the one step that cannot be undone, and it happened after a gate said no.

This contradicts the documented contract. `home/private_dot_claude/dot_smithers/workflows/lib/flow-spec.ts:12-15`:

> A red gate after retries either fails the run outright (`none`) or parks in an approval pause the composer opted into for a risky block (`approval` …).

Neither happens. `se-flow.tsx` contains **zero** references to `block.waive` — the validator checks the policy against the registry (`flow-validate.ts:108`) and the interpreter then never reads it. There is no stop-on-red anywhere in the render: `dispatchableBlocks` (`lib/flow-run.ts:135`) withholds a block only while a `bindTo` target has no durable row yet, and it inspects row *presence*, never row *status*. The single status consumer in the interpreter is `anyBlockFailed` (`se-flow.tsx:541`), used only to decide whether the epilog may render early.

`after` edges therefore express ordering and nothing else, and `bindTo` would not have helped: a red block still writes a `block_output` row, which satisfies the proof.

The severity is not uniform across blocks. A red `secret-scan` followed by a green `pr` is the same mechanism, and that combination publishes content the scan refused — the exact surface KTD13 exists to protect. The validator's `scan-before-external` invariant guarantees a scan block is an *ancestor*, not that it passed.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the render loop around line 226 is where a red block must withhold its successors, and where `waive: "approval"` would render the escalation `Approval` instead.
- `home/private_dot_claude/dot_smithers/workflows/lib/flow-run.ts` — `dispatchableBlocks` currently keys on row presence; deciding whether the status check belongs here or in the interpreter is the first call to make.
- `home/private_dot_claude/dot_smithers/workflows/lib/flow-spec.ts` — if the enforcement lands somewhere other than the interpreter, the `WAIVE_POLICIES` comment needs to say where.

## Open decisions

- **Whether a red block stops the whole run or only its `after`-descendants.** Stopping descendants is the narrower reading and keeps independent branches useful; stopping the run matches the "fails the run outright" wording. The epilog must still render either way — it does today, via `anyBlockFailed`.
- **Whether the fix belongs in `dispatchableBlocks` or the interpreter.** Putting it in `dispatchableBlocks` gives one place that answers "may this block run", but that function is currently pure over ids and would need the status lookup passed in.
- **What `waive: "approval"` should render.** The schema promises an approval pause on a red gate; no node exists for it. `renderBudgetApproval` is the nearest shape to copy, but the budget pause is once-per-run and this one is per-block.
- **Whether a red `secret-scan` deserves a hard stop independent of the waive policy**, given `compute` blocks may only declare `none` anyway (`block-registry.ts:21`), so no spec can ask to waive it.

## Resolution

A red block now withholds its successors, transitively, and the `waive` policy decides whether that stop is final or an approval pause.

**Where enforcement lives.** In `dispatchableBlocks` (`workflows/lib/flow-run.ts`), not the interpreter. It was already the pure function that answers "may this block run", so the policy is read at the point of decision and is unit-testable without a live engine. `se-flow.tsx` only renders what the decision asks for. `flow-spec.ts`'s `WAIVE_POLICIES` comment now names that site — the whole defect was a contract documented with no implementation anywhere, and a second unnamed one would repeat it.

**What changed.**

- `dispatchableBlocks` takes the recorded rows (`{nodeId, status}`) instead of just node ids, plus a gate-approval reader. It returns `{dispatchable, gateApprovals, withheld, withheldBy, stops}`. A red block is added to a withholding set; any block with an `after` or `bindTo` edge into that set is withheld and joins the set, so withholding closes transitively in one forward pass over the topological order. Independent branches are untouched — a red block stops what depends on it, not the DAG.
- `waive: "approval"` renders an `Approval` per red block at node id `approve-waive-<blockId>` (the budget ack stays one-per-run; a gate waive is per block, and one shared id would let an ack for one block waive another). `onDeny="fail"`, matching the budget pause and the pipeline's gates. Approve releases the successors, deny and undecided both withhold; an unreadable decision defaults to withholding.
- The `outcome` row and `outcome.json` gained a verdict: `completed` / `stopped-by-red-gate` / `parked-for-waive-approval`, plus `stoppedBy` naming the block, its kind and its status. Both persisted fields are `.nullish()` so a run persisted before the change still resumes. A withheld block is recorded as `stopped` rather than `non-terminal`, so the terminal reviewer is not sent chasing legs that were never dispatched.
- Epilog readiness moved to `epilogShouldRender` in `flow-run.ts` (replacing `se-flow.tsx`'s `anyBlockFailed`). Withholding cannot starve it: withholding only ever happens because a block recorded a red row, which is exactly what the "any red" arm sees. The condition is monotone as rows accumulate, which is what keeps the epilog rendering once.

**The field "red after retries were spent" keys on.** The `status` of the block's settled `blockOutput` row, resolved through `blockRowNodeId` — the block node `b:<id>`, or the guard's `b:<id>-crashed` node when every attempt threw. There is no attempt counter to consult, because the presence of that row is itself the proof that retries are spent: Smithers persists an output row only on the attempt that RETURNS (a thrown attempt emits `NodeFailed` and re-runs, writing nothing), and a red gate is a returned value rather than a throw — the classify/effect task returns `status: "failed"` and completes. So a red row can never be a transient attempt a later retry replaced. A crashed block counts as red: its `-crashed` row is `non-terminal`, and anything that is not `green` is red, the same rule `reviewer.ts` applies to the outcome record.

**Open decisions, as settled.** Red stops descendants, not the whole run (the narrower reading; independent branches stay useful). A red `secret-scan` needs no special case — `compute` blocks may only declare `waive: "none"`, so its hard stop is structural rather than a policy choice.

**Proof.** Unit tests only, in `workflows/lib/flow-run.test.ts` (52 tests in that file, 561 across the suite, 0 fail) plus `bun build workflows/se-flow.tsx`. This was **not** re-verified by a live `se flow` run: the fix edits the interpreter's module graph, and KTD1 forbids that while a run is live or parked, so a live check is a separate, operator-scheduled step.
