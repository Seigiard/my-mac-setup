---
title: Resume-safe dynamic composition in a durable workflow engine
date: 2026-08-14
category: architecture-patterns
module: se-pipeline
problem_type: architecture_pattern
component: development_workflow
severity: high
symptoms:
  - "RESUME_METADATA_MISMATCH on resume after any edit to a file in the interpreter workflow's module graph while a run is live or parked"
  - "Recovery only via --accept-workflow-change, which shifts replay-determinism onto the operator"
applies_when:
  - "Composing dynamic flows on a durable engine (Smithers) that binds run identity to workflowHash"
  - "Deciding whether flow variability lives in workflow code or in a validated input spec"
  - "Shipping changes to workflow code while se-pipeline runs are live or parked"
  - "Verifying engine breakage behavior deliberately instead of assuming it"
related_components:
  - tooling
tags:
  - smithers
  - se-pipeline
  - workflow-hash
  - resume-safety
  - dynamic-flow-composition
  - static-interpreter
  - durable-execution
  - se-flow
---

# Resume-safe dynamic composition in a durable workflow engine

## Context

The se-pipeline project runs long-lived, crash-safe agent flows on Smithers. A run can park for hours at an approval gate or a budget breach and must resume later with zero re-executed tasks. Smithers binds a run's identity to its workflow code: `workflowHash` is computed over the statically-imported module graph's file contents, never over the rendered tree (dynamic-flow-composition plan, verified against engine documentation and re-proven empirically by the U0 spike, `docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md:144`). So editing any file in the interpreter's module graph while a run is live or parked breaks that run's resume.

The pain was measured before it was designed around (session history): mining one day of prior sessions during the 2026-08-13 brainstorm counted `RESUME_METADATA_MISMATCH` ×32 in a single day, and on smithers-orchestrator 0.29 there was no recovery path at all — a stranded run restarted from scratch. The 0.32 upgrade added `se resume ... --accept-workflow-change` as an escape hatch, and the delivery discipline (check `se list` before touching sources) was practiced in that upgrade session before being codified in the runbook.

Dynamic flow composition (`se flow`) wants the opposite of a frozen workflow: a different flow shape per task, composed by an orchestrator from a block catalog. The naive route — generating a TSX workflow file per task — makes every composed flow a new workflow identity and reintroduces the resume-failure class (Smithers issue #1493). Replacing the engine was considered and rejected (session history): a ce-pov verdict on Temporal returned Reject — dynamic assembly is native to Smithers; what was hardcoded was the pipeline, not the engine.

The recorded resolution (KD2 + KTD1, instantiating R7): flow-as-data interpreted by one static workflow. From the plan:

> R7. The interpreter workflow file is identical across runs; only the spec input varies. (`docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md:63`)

> KTD1. **Spec-as-input interpreter: one static `workflows/se-flow.tsx`, spec passed as run input, block ids derived deterministically from spec content** — chosen over TSX codegen: engine hashes the module graph, not the rendered tree, so a static file with varying input is resume-stable. ... **Zero-in-flight rule:** files in the interpreter's statically-imported module graph (interpreter, blocks, shared libs) are edited only when no run is live or parked; otherwise runs are drained first or explicitly written off via their outcome records. (`docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md:153`)

The runbook states the operational consequence (`docs/se-pipeline.md:177-179`, paraphrasing the Russian): the interpreter file does not change between runs — only the input spec varies (R7/KTD1) — therefore `workflowHash` is stable and resume works for any composed flow.

**The honest scope of the claim (session history — doc-review finding, P1).** The first draft of the plan claimed the static interpreter "eliminates" the #1493 class. The three-envelope doc review disproved the strong form: the engine hashes the workflow's **entire import graph**, and every block in the block library is a file in that graph — editing *any* block while *any* run is parked (and budget-park is a normal, expected state) still kills that run on resume. The design **narrows** the surface (composing a new flow no longer changes the workflow) but does not remove it; KD2/KTD1 were reworded to say exactly that. The plan's own feedback loop — reviewer files an issue, block gets fixed — guarantees continuous block-library edits, which is why the zero-in-flight rule is part of KTD1 itself, not a side note.

## Guidance

1. **In a durable engine, workflow code is part of the run's identity — treat it as immutable while any run is in flight.** Smithers hashes the module graph; an edit to any imported file between launch and resume yields `RESUME_METADATA_MISMATCH` (`docs/se-pipeline.md:319-320`). This applies to the whole graph at once — interpreter, block library, shared libs — not just the entry file (`docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md:134` and `:153`).

2. **To get dynamic behavior, move variation from code to validated input.** One static interpreter (`home/private_dot_claude/dot_smithers/workflows/se-flow.tsx`) receives the flow spec as run input — `inputSchema` takes `specPath` plus operator-supplied command fields; `readSpec` loads and validates the spec through `validateFlowSpec` before anything is staged. The interpreter renders the spec's block DAG through a fixed block registry (`home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts` via `buildRegistry`) with deterministic node ids derived from spec content (`blockNodeId` prefixes every spec block id with `b:` in `home/private_dot_claude/dot_smithers/workflows/lib/flow-run.ts`, so spec names can never collide with ladder-derived ids). Even the subflow map and the mirror-key set are fixed and closed in the interpreter file, explicitly "so this workflow file stays identical across runs (R7)". The spec is declarative data, not code — and command-bearing fields carry operator-source references, never inline command strings (KTD15). The launched flow is frozen: recomposition means a new run, never in-place mutation (session history).

3. **Deliver interpreter-code changes only at zero in-flight runs.** The runbook's delivery procedure ends with exactly this rule: editing sources between launch and resume breaks resume without `--accept-workflow-change` — deliver at zero in-flight runs (`docs/se-pipeline.md:126-128`). Engine upgrades start with the same precondition: zero in-flight runs per `se list` (`docs/se-pipeline.md:132`).

4. **Keep an explicit, operator-owned escape hatch — and treat it as a determinism transfer, not a routine fix.** When the mismatch does happen, recovery is `smithers up workflows/se-pipeline.tsx --run-id <id> --resume true --accept-workflow-change`, which re-blesses the run's metadata; from that moment replay-determinism is on the operator, and the engine warns about this explicitly (`docs/se-pipeline.md:319-323`). Related targeted repair, same spirit: a failed final task with `retries=0` does not re-run on resume; the fix is `smithers retry-task ... --run-id <id> --node-id <node>` — reset one node, not the run (`docs/se-pipeline.md:330-332`).

5. **Prove the breakage mode deliberately in verification instead of assuming the engine's semantics.** The host-verification checklist's engine spike (U0) covers both sides of the invariant with throwaway runs (`docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md:44-51`):
   - 1.1 — launch the same workflow twice with different inputs; both runs must report the same workflow identity hash (hash stability across composed flows);
   - 1.2 — kill a run mid-block, `se resume`; zero completed tasks re-execute (resume actually works);
   - 1.4 — edit an imported helper while a run is parked, then resume; resume must fail with the documented error, "proving the KTD1 rule rather than assuming it". The checklist marks it: "Scenario 1.4 deliberately breaks a run. Use a throwaway fixture run, never real work."

   That checklist has `status: open` as of this writing — the live-engine claims above are design-verified and unit-tested, but the deliberate-breakage proof on the host is still pending.

## Why This Matters

- **It narrows an expensive failure class structurally instead of managing every instance operationally.** With TSX codegen, every composed flow risks the #1493 resume failure; with the static interpreter, composing flows never touches code, so only genuine block-library maintenance remains on the dangerous path — and that path is governed by one rule (zero in-flight) instead of per-flow discipline (KD2, `docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md:42`).
- **It keeps validation deterministic.** A spec is data with a schema; the validator can refuse a bad flow before a staged worktree exists. Generated code cannot be gated that cheaply.
- **It preserves the durable-engine contract under composition.** A parked run — waiting at an approval, or degraded on a budget breach — resumes bit-for-bit regardless of what other flows launched meanwhile, because launches never touch code.
- **The escape hatch stays honest.** `--accept-workflow-change` is recorded as a liability transfer, so nobody normalizes editing code under live runs "because the flag exists".

## When to Apply

- Designing any system on a durable/replay engine (Smithers, Temporal-style) where behavior must vary per task: put the variation in a validated input document, not in generated workflow code.
- Before editing anything in a durable workflow's import graph: check for in-flight runs first (`se list`); drain or explicitly write runs off before touching code.
- When a parked run must resume after a code change anyway: use the engine's explicit re-bless flag, log that determinism is now operator-owned, and prefer draining next time.
- When verifying such a system: spend a throwaway run to trigger the documented breakage (edit-under-park) and confirm the error, alongside the positive proofs (hash stability, zero re-execution on resume).

## Examples

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the static interpreter: header comment states the whole invariant ("Its statically imported module graph never changes between runs — only the spec passed as input varies — so Smithers' workflowHash ... is stable and resume works for any composed flow"); `inputSchema` (`specPath`, `budgetUsd`, `setupCmd`, `validateCmd`), `readSpec` → `validateFlowSpec`, fixed `SUBFLOW_WORKFLOWS` map, closed mirror-key set (KTD3).
- `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts` — the fixed block registry the interpreter dispatches from; the catalog is generated (`se blocks --json`, KTD6), the orchestrator composes from the catalog, never from TS source.
- `home/private_dot_claude/dot_smithers/workflows/lib/flow-run.ts` (committed behavior at HEAD) — deterministic spec-to-node derivation: `BLOCK_NODE_PREFIX = "b:"`, `blockNodeId`, `dispatchNodeId`, `topoOrder`, `specHash`, `bindProofTargets`.
- Subflow boundary gotcha for any block library (session history): subflow output crosses to the parent through a typed SQLite row, so an absent optional field comes back as NULL and `z.string().optional()` rejects it — block schemas at these seams use `nullish()` on both sides.

## Related

- `docs/se-pipeline.md:172-189` — `se flow` section: one static interpreter, spec varies, hash stable; `docs/se-pipeline.md:314-332` — resume particulars: `RESUME_METADATA_MISMATCH`, `--accept-workflow-change`, `retry-task`.
- `docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md` — the R7/KD2/KTD1 decisions (status: done).
- `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` — the deliberate-breakage verification protocol (status: open).
- `docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md` — sibling se-pipeline pattern; the flow validator ties the two together (secret-scan required before every external block).
