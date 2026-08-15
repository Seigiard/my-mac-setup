---
title: The se-flow work block embeds a plan path from outside its own staged worktree
type: bug
date: 2026-08-15
status: open
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
