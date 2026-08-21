---
title: "An se-flow run that writes into the main checkout reports \"no content change\", not the cause"
short_description: "An se-flow run that writes into the main checkout reports \"no content change\", not the cause"
type: "follow-up"
category: "se-pipeline"
tags: ["se-pipeline","follow-up"]
date: "2026-08-15"
status: "open"
priority: "low"
---

# se-flow has no main-checkout escape diagnosis

## Why this exists

`se-pipeline` carries a diagnosis for the failure in `docs/issues/2026-08-14-012`: staging records `repoDirtyDigest(repo)`, the work gate re-reads it, and `mainCheckoutEscapeReason` (`home/private_dot_claude/dot_smithers/workflows/lib/gates.ts`) appends "the main checkout became dirty during the work stage" to the verdict without ever changing the gate's state.

`se-flow` records no such digest. Its equivalent invariant is the KTD14 tree-hash comparison in `workflows/lib/blocks/index.ts:98-102`, over the trees `commitWorkEffect` computes in `workflows/lib/block-effects.ts:113-117`; its red row reads "worktree tree hash equals base — no content change (KTD14)". An operator seeing that row is told the agent produced nothing; they are not told their own checkout may be holding the work.

The doorway that caused the escape is closed — `docs/issues/2026-08-15-002` freezes the plan and hands the agent a copy outside every repository — so this is a diagnosis for a failure that should no longer happen, not a fix for a live one.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the `staging` row would gain a `repoDirtyDigest` field (`.nullish()`, like `plans`), and the `commit-work` block's effect would need the value.
- `home/private_dot_claude/dot_smithers/workflows/lib/block-effects.ts` — `commitWorkEffect` computes the trees; the gate that compares them is in `workflows/lib/blocks/index.ts`. The diagnosis would attach at one of the two.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `mainCheckoutEscapeReason` already exists and is advisory-only; nothing new is needed there.

## Open decisions

- **How the no-workspace mode is suppressed.** A flow with no workspace-needing block runs with `worktreePath === repoPath` and stages nothing, so a dirty main checkout is the normal state and the comparison must not run at all. The staging row's absence is already that signal — but the check has to consult it, and a compute effect currently receives only `ComputeEffectContext`.
- **Whether the digest belongs in the `staging` row or in the `commit-work` block's own input.** The row keeps it out of the spec, which is right; a compute effect reading a prolog row is a new coupling for the interpreter.
- **Whether it is worth carrying at all** now that the plan copy closed the doorway. The pipeline's version cost little and catches an operator editing their own checkout mid-run — which it deliberately does not gate on.
