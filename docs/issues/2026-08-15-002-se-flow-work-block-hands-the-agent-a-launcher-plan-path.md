---
title: "The se-flow work block embeds a plan path from outside its own staged worktree"
short_description: "The se-flow work block embeds a plan path from outside its own staged worktree"
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-15"
status: "done"
priority: "low"
closed: "2026-08-15"
---

## Why this exists

`se-flow` has the same doorway `se-pipeline` had in `docs/issues/2026-08-14-012-work-agent-escapes-the-isolated-worktree.md`, and the fix for that issue did not touch it.

The flow stages its own isolated worktree on a run branch (`home/private_dot_claude/dot_smithers/workflows/se-flow.tsx:169`, `stageRunWorktree`) and dispatches the `work` block's agent with that worktree as cwd (`se-flow.tsx:410`, `def.makeAgent({ worktreePath: effectCtx.worktreePath, ... })` → `makeWorkAgent` in `workflows/lib/blocks/index.ts:183`).

The prompt that agent receives is built at `workflows/lib/blocks/index.ts:215`:

```ts
return i.planPath ? `Execute the plan at ${i.planPath} headless via ce-work mode:return-to-caller.` : `Implement headless: ${i.prompt ?? ""}`;
```

`planPath` comes from the flow spec's block input — an operator-supplied path that points into the main checkout, exactly like `se-pipeline`'s `gate0.planPath` did. On `run-1786717826270` the work agent resolved every repository path relative to the plan's own repository and wrote its changes into the operator's main checkout while the run branch stayed empty; nothing about that mechanism is specific to `se-pipeline`. The `repro`, `analysis`, and `subtasks` blocks share `implementationAgent` but embed free text, so only `work` carries a path.

`se-flow` also has less of a safety net than `se-pipeline` did: the KTD14 tree-hash comparison lives in `workflows/lib/block-effects.ts:114` (`workCommitAndProve`), so an escape still surfaces as "no content change" with no diagnosis naming the main checkout.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts` — the `work` block's `buildPrompt`, and whether `inputSchema.planPath` should be resolved to a staged copy before the prompt is built.
- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the staging task is where a frozen plan copy would be produced (`stageRunPlan` in `workflows/lib/staging.ts` already exists and takes a branch plus the expected plan hash).
- `home/private_dot_claude/dot_smithers/workflows/lib/block-effects.ts` — where a main-checkout escape diagnosis would attach (`mainCheckoutEscapeReason` in `workflows/lib/gates.ts` already exists and is advisory-only).

## Open decisions

- **Where the flow gets an expected plan hash.** `stageRunPlan` verifies the copy against gate 0's `planHash`; `se-flow` has no gate 0. Either hash at staging time and treat that as the flow's own freeze point, or give `stageRunPlan` an "expected hash unknown" path — the second weakens the guarantee for both callers and is probably wrong.
- **Whether the block layer or the flow layer owns the rewrite.** `buildPrompt` is pure and takes only the block input, so the copy's path has to be substituted into that input upstream (the interpreter, `se-flow.tsx:410`), or `buildPrompt` gains access to the run context.
- **Whether the escape check belongs in `block-effects.ts` at all**, given `se-flow` may run with `worktreePath === repoPath` when no workspace is needed (`se-flow.tsx:192`) — in that mode a dirty main checkout is expected, and the comparison must be suppressed rather than reported.

## Resolution

The flow now freezes its own plan copy and hands the agent that path, reusing `stageRunPlan` from `workflows/lib/staging.ts` — the same function the `se-pipeline` fix produced. No second copier was written.

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the `staging` output gained `plans: [{blockId, planPath, planHash, copyPath}]`, `.nullish()` so a run persisted before this field still resumes (and simply keeps the operator's path, as it always did). The staging task freezes every plan-bearing agent block's plan **before** it takes the repo lock: an unreadable plan path refuses the launch with no lock and no worktree left behind by hand. Each render then calls `resolveStagedPlans`, and the agent branch of `renderBlock` substitutes the copy's path into the block input before `buildPrompt` sees it, appending `frozenPlanNote(copyPath)` to the rendered prompt.
- `workflows/lib/staging.ts` — new `StagedPlan` / `PlanResolution` types and `resolveStagedPlans(plans, branch, opts?)`: re-freezes each recorded plan through `stageRunPlan` and reports, per block, the path its prompt may name. Idempotent when the copy is already right, self-healing when the copy vanished, and a refusal when the launcher's plan no longer hashes to what the run froze. A refusal never falls back to the recorded `copyPath` — the copy can be intact while the spec behind it moved.
- `workflows/lib/flow-run.ts` — pure helpers: `blockPlanPath`, `planBearingAgentBlocks` (agent blocks only; a `doc-review` subflow's `planPath` goes to a workflow that copies the document into its own harness, and no coding agent runs against it — it also throws when two blocks name different plans sharing a basename, because `stageRunPlan` keys the copy on the basename and one block would silently execute the other's plan), `withStagedPlanPath`, and `frozenPlanNote`.
- `workflows/lib/blocks/index.ts` — the `work` prompt now carries the guard the concrete path was beating: the plan file is an input, not a location; never resolve a path relative to it, never write to it; **every** repository path belongs to the agent's cwd. The "frozen copy living outside every repository" sentence is appended by the interpreter instead of written into `buildPrompt`, because only the interpreter knows whether that is true for this render.
- Placement is unchanged from the pipeline's: the copy lands BESIDE the worktree (`<worktree>-plan/`), never inside it, or `commitWorkGuarded`'s `git add -A` would commit it and make `treeHash(worktree) !== baseTree` for a leg that did nothing — destroying the KTD14 invariant. `cleanupSnapshot` in the flow's epilog already removes that sibling directory.
- Tests: `workflows/lib/blocks/index.test.ts` (the prompt names the frozen copy and not the launcher path; with no staged copy the operator's path stands; the cwd guard is present), `workflows/lib/flow-run.test.ts` (which blocks bear plans, the basename collision, the substitution, the note), `workflows/lib/staging.test.ts` (`resolveStagedPlans` resolves, heals a deleted copy, refuses a plan edited between staging and use, and reports nothing for a run that froze nothing).

**Open decision — where the flow gets an expected plan hash.** It hashes at staging and treats that as the run's freeze point, using `planContentHash` from `workflows/lib/gates.ts` — the same function gate 0 and the KTD7 re-hash use, so no second hashing scheme exists. The hash is persisted in the `staging` row, so its value is fixed for the run and every later render verifies against it. The alternative (an "expected hash unknown" path in `stageRunPlan`) was rejected: it weakens the guarantee for `se-pipeline` too.

**Open decision — block layer or flow layer.** The flow layer. `buildPrompt` stays pure over its declared input; the interpreter substitutes at the one seam that knows both the staged copy and the launcher's path — `renderBlock`'s agent branch in `se-flow.tsx`, right where `def.buildPrompt` is called.

**Open decision — whether the escape check belongs in `block-effects.ts`.** Not taken here, and deliberately: with no launcher path in the prompt there is nothing pointing outward, and the `worktreePath === repoPath` mode makes a dirty-main-checkout comparison actively wrong without a suppression signal to carry. That signal (and the diagnosis it would feed) is filed as `docs/issues/2026-08-15-005-se-flow-has-no-main-checkout-escape-diagnosis.md`. The no-workspace mode needed no protection here either: `se-flow.tsx` renders the `staging` task only under `workspaceNeeded`, so no copy is frozen and the prompt keeps the operator's path.

Proven by unit tests only. No live `se flow` run was made — editing the interpreter's module graph is forbidden while a run is live or parked (KTD1), so a live re-verification is the operator's call.
