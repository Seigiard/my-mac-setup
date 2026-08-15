---
title: Unified stage right-sizing evaluator for code-review and doc-review
type: follow-up
date: 2026-07-27
status: wontfix
closed: 2026-08-15
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

## Resolution

Closed without building the evaluator, on 2026-08-15, after reading the two stages against the design this issue proposed. The finding is that both levers are already held by something else, and an evaluator on top of them would either duplicate a gate or overrule the operator.

**doc-review is right-sized by the command the operator types.** The stage runs only when `docReview: true`, and the operator never types that flag — `se-work` sets it false and `se-review-and-work` sets it true (`se-pipeline.tsx` `inputSchema.docReview`). Choosing between the two commands IS the right-sizing decision, made by the person who knows whether the plan has been reviewed. An evaluator layered on top could only do one of two things: agree with the operator, which costs a classifier and changes nothing, or skip a plan review the operator explicitly asked for. The second is not right-sizing, it is overruling. The parent plan's two-command split (KTD-C) already answered this question; the answer was just recorded in a different file.

**verify-code is right-sized inside the plugin.** The pipeline dispatches `ce-code-review` with `mode:agent base:<sha>` and no depth token, so the skill's `depth:auto` default applies — its Stage 3c reduces the reviewer roster on trivial, low-risk, code-only diffs by itself. A pipeline pre-gate would be a second gate over the same diff, which this issue's own open decision named as the thing to avoid.

**What is left unclaimed, and why it is not worth a gate.** The verify-code stage runs two legs, and only the claude one self-sizes; the opencode leg has no equivalent. It is also the cheapest of the three legs, so a deterministic pre-gate over it would save little and would add a mechanism able to drop a reviewer. This issue's own bias table says the review stages run when unsure, and the cheapest way to honour that is to have no skip path at all.

**The simplify precedent does not generalise, and that is the point.** Simplify's bias is SKIP when unsure: a redundant simplify costs money and carries auto-apply risk on a low-value change, while skipping it leaves code slightly untidy. Both review stages invert that — a missed defect or a flawed plan outranks a redundant review — so the same machinery pointed at them would be tuned against its own bias.

If the cost of a review stage ever becomes the binding constraint, the lever to reach for first is the roster and the model inside `lib/agents.ts`, which is one number per profile with the incident that produced it recorded next to it — not a new autonomous skip decision.
