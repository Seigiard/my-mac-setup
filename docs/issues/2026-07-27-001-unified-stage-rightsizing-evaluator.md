---
title: Unified stage right-sizing evaluator for code-review and doc-review
type: follow-up
date: 2026-07-27
status: open
parent-plan: docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md
---

# Unified stage right-sizing evaluator (code-review + doc-review)

## Why this exists

The se-pipeline (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`) runs expensive multi-leg stages — verify-doc (two external plan-review legs), simplify (two report legs + apply + verify), verify-code (two external code-review legs). Each pays real time/money on every run regardless of whether the input warrants it. compound-engineering skills already right-size their own work (see Precedents); the pipeline should do the same per stage.

The parent plan (se-simplify + se-work fork) resolved this **only for the simplify stage** — simplify gets a right-sizing gate there (see that plan's R14 / KTD-I). This issue tracks generalizing the same idea to the **code-review** and **doc-review** stages, which were deliberately left out of the parent plan to avoid scope creep and reopening its two-command doc-review split (KTD-C).

## What compound-engineering already does (precedent to mirror)

- **Deterministic preflight (code, no LLM).** `ce-simplify-code` skips a scope that is documentation-only, generated, vendored, lockfile, or purely mechanical (formatting, rename) churn — gating on the *kind* of change, not size. `ce-code-review` counts only executable-code lines toward its thresholds and skips runtime-focused reviewers on instruction-prose-only diffs.
- **Cheap LLM triage sub-agent.** `ce-code-review`'s "Trivial-PR judgment" spawns a lightweight sub-agent on the cheapest capable model with the PR title/body/changed-file-paths and asks "is this an automated or trivial PR that does not warrant a code review?" (lock-file bumps, release commits, chore version increments). Its bias is explicit: **"when in doubt, answer no — false negatives (skipped reviews that should have run) are more costly than false positives."**
- **Depth tokens + size paths.** `ce-code-review` `depth:auto` (default) reduces the reviewer roster on trivial/low-risk/code-only diffs (Stage 3c); `depth:full` disables the gate. `ce-work` Phase 0 classifies Trivial (1-2 files, no behavioral change) → implement inline.

## Design direction

A shared `lib/stage-gate.ts` (already introduced for simplify by the parent plan) consulted by each stage: **deterministic pre-check** (empty diff / doc-only / lockfile / size + file-type) → **optional cheap Haiku classifier** for the judgment call ("is this substantive enough to warrant the stage?") → run/skip decision.

**Per-stage bias is the key non-obvious point — it is NOT uniform:**

| Stage | Skipping wrongly costs | Running wrongly costs | Bias when unsure |
|---|---|---|---|
| doc-review | building on a flawed plan (high) | some $/min (low) | **RUN** |
| code-review | shipping a bug (high) | some $/min (low) | **RUN** |
| simplify | slightly untidy code (harmless) | wasted $ + auto-apply risk on a low-value change | **SKIP** *(handled in parent plan)* |

The review stages (doc-review, code-review) are read-only assessments — a missed defect is worse than a redundant review, so their bias is "run when unsure," matching `ce-code-review`'s explicit rule.

## Open decisions for this issue

- **Deterministic-only vs deterministic + LLM.** Per the repo's own guidance (code answers what code can; LLM only for genuine classification), start deterministic (empty/doc-only/lockfile/size) and add the Haiku classifier only where a deterministic rule cannot decide.
- **doc-review gate vs the two-command split (KTD-C in the parent plan).** An evaluator that auto-decides doc-review partially overlaps the parent plan's `se-work` / `se-review-and-work` split. Decide whether the evaluator (a) replaces the split (one command, evaluator decides, plus an explicit force override), or (b) complements it (the command sets intent, the evaluator only right-sizes within that intent). The external claude review of the parent plan noted `artifact_readiness` frontmatter is a ready signal for auto-detection.
- **verify-code already has Stage 3c-style sizing inside `ce-code-review`.** Decide whether the pipeline needs its own pre-stage gate on top, or whether delegating to the plugin's existing small-diff path is enough (avoid double-gating).
- **Durable/headless context.** The pipeline has no human to ask "is this trivial?" — the gate must be autonomous (the `ce-code-review` Trivial-PR sub-agent pattern is autonomous and fits).

## Reference

Parent plan: `docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md` (simplify gate: R14, KTD-I; this issue is the deferred generalization). compound-engineering skills: `ce-code-review` (Quick Review Short-Circuit, Trivial-PR judgment, Stage 3c), `ce-simplify-code` (preflight), `ce-work` (Phase 0 sizing).
