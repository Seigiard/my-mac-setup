---
title: A red block does not stop the se-flow run — its successors run, including pr
type: bug
date: 2026-08-15
status: open
parent-plan: docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md
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
