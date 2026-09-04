---
title: Gate bias follows blast radius
date: 2026-08-21
category: design-patterns
module: agent-platform
problem_type: design_pattern
component: development_workflow
severity: medium
related_components:
  - tooling
applies_when:
  - "Adding a heuristic or classifier gate that decides whether a pipeline stage runs at all"
  - "Choosing the default outcome for an inconclusive gate decision"
  - "Gating a stage that auto-mutates code or spends money per run"
  - "Gating a read-only review or analysis stage"
  - "Generalizing one stage's run/skip gate to stages with a different blast radius"
tags:
  - stage-gate
  - right-sizing
  - skip-when-unsure
  - run-when-unsure
  - blast-radius
  - se-pipeline
  - smithers
  - simplify
---

# Gate bias follows blast radius

## Context

The se-pipeline (a durable Smithers workflow that runs coding agents) gained an always-present "simplify" stage that auto-edits code after the work stage (`docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md`, merged in commit `ba16224`, reachable from `main`). Because the stage mutates code and spends money on agent legs, it is not user-toggled — a heuristic gate (`shouldRunSimplify` in `stage-gate.ts`) decides per run whether the work-diff is worth a simplify pass.

> **Where this evidence lives now.** The Smithers runtime and both executors were removed on 2026-09-01, so every `stage-gate.ts` line reference below is readable only in git history (see `docs/decisions/0001-se-pipeline-architecture-redirection.md`). The rule they demonstrate is stage-agnostic and is applied today by gates that never ran under Smithers; those are the Examples.

That gate forced a design question every heuristic gate faces: **which way do you lean when the heuristic can't decide?** The plan's decision record (KTD-I; rationale in R14) answers it with a rule that generalizes beyond this pipeline.

## Guidance

**Set a heuristic gate's tie-breaking bias by the blast radius of the stage it guards, not by a generic preference for running or skipping.**

- A gate in front of a **mutating** stage (auto-applies edits, sends money-costing agent legs, writes anywhere) must **skip when unsure**. A wrong skip is cheap and self-describing: the code stays slightly untidy, and the next run gets another chance. A wrong run auto-edits low-value code and burns budget.
- A gate in front of a **read-only** stage (review, analysis, report-only checks) must **run when unsure**. A wrong run wastes only compute; a wrong skip silently drops a finding you will never see. The cheapest way to honor this bias is often to build no skip mechanism at all — which is what this pipeline's review stages do (see `2026-07-27-001`, resolved wontfix: "The simplify precedent does not generalise, and that is the point").

Two implementation corollaries from the implemented gate:

1. **Layer deterministic rules before the fuzzy layer, and make every layer inherit the same bias.** `shouldRunSimplify` is a pure function over parsed `git diff --numstat` (historical, `stage-gate.ts:105-122`): empty diff → clear skip; only docs/lockfile/generated/vendored/binary churn → clear skip; ≥20 substantive executable-code lines → clear run. Only the borderline middle returns `inconclusive: true` and defers to a cheap classifier (Haiku) — which per the header comment "keeps the same skip-when-unsure bias" (historical, `stage-gate.ts:6-8`). The bias is a property of the whole gate stack, not of one layer.
2. **A biased skip must be loud, never silent.** The gate returns `run: false` with a human-readable `reason` naming the categories it saw (historical, `stage-gate.ts:107, 111, 119`), and the pipeline reports the stage as `skipped` with that reason — per the plan, "never a silent pass" (R14).

The same bias propagates into failure handling: when the simplify stage's post-apply verification fails, the whole apply is reverted and the run degrades to "no tidy this run" (plan OQ3) — accepting a lost tidy rather than risking a bad mutation, the same lean the gate takes.

## Why This Matters

The asymmetry is real money and real code, not theory. In se-simplify run id `85e40697-1cb3-4b25-b4f6-61e17dd2d677` (2026-08-20, not a git commit), the simplify apply leg ran for its full 20-minute budget — after two report legs of 4–5 minutes each — and was then killed by the timeout, forcing a full revert: maximum spend, zero applied value (`2026-08-20-009`). That incident is what the wrong-run cost looks like even when the gate correctly said "run"; a gate that also ran on borderline diffs would pay that price for diffs with nothing to gain. The wrong-skip cost, by contrast, is invisible: slightly untidy code that the next substantive diff's run will catch.

Without a stated bias, gate authors default to symmetry ("50/50, just pick a threshold") or to run-when-unsure ("better safe than sorry") — which is exactly backwards for a mutating stage, where "sorry" is the run, not the skip.

## When to Apply

- Any time a heuristic, classifier, or threshold decides whether an **automated stage runs at all**: auto-fix passes, auto-refactor stages, codemod triggers, auto-merge bots, notification/paging triggers, expensive LLM legs.
- First classify the guarded stage: does it mutate state, spend nontrivial money, or notify humans? → skip-when-unsure. Is it report-only? → run-when-unsure.
- When writing the inconclusive branch of a layered gate (deterministic rules + classifier fallback): the fallback inherits the same bias, and the deterministic layer's "neither rule fired" result defaults to the biased outcome (see `run: false, inconclusive: true` at the historical `stage-gate.ts:117-121` — the caller may consult the classifier, but the standing answer is already "skip").
- Not a license to gate everything: the review stages here run unconditionally today; generalizing the gate to them was considered and deliberately rejected (`2026-07-27-001`, wontfix).

## Examples

The stage gate this pattern was extracted from (`shouldRunSimplify`, a pure function over
`git diff --numstat` that returned `run: false, inconclusive: true` for the borderline middle,
with a test pinning that default) lived in the Smithers pipeline and was deleted with it. The
shape it demonstrated — encode the bias in the type, so "undecided" is spelled "skip unless a
smarter layer overrules me" — is preserved here because the repo now applies the same rule in
three places that never ran under Smithers.

**Advisory gate over a mutating agent → fail open.** `home/dot_local/bin/executable_test-oracle-guard`
inspects proposed test edits and flags negative assertions. It can only cost an agent context,
never correctness, so its header states the bias outright:

```
# Fails open: missing input or tooling exits 0 so a broken guard never blocks
# an agent.
```

**The same bias, pinned by a mutation test.** `docs/plans/2026-09-03-0833-feat-agent-hooks-core-plan.md:196`
carries the acceptance criterion for the hook-policy dispatch layer:

> A policy that throws yields allow, and the mutation test proves the bias pin: inverting the
> catch to deny fails the test (fail-open pinned, per `gate-bias-follows-blast-radius`).

That is rule 3 applied without a pipeline: the standing answer is written into a test, so a later
edit that flips it goes red rather than silently inverting the gate.

**Subtractive boundary over an irreversible export → fail closed.** `se-doc-review/SKILL.md:27`
gates the peer launch on a secret scan: "require `gitleaks` and run this fail-closed scan before
creating tabs." Content that reaches a third-party model cannot be recalled, so an unavailable
scanner refuses the launch instead of waving it through. Same doc, opposite default — the blast
radius, not the gate's position in the flow, decides.

**Deployment guards inherit it too.** `CONCEPTS.md` records both directions as settled vocabulary:
*Hooks core* — "Every failure path fails open"; *Disposable home* — "The guard fails closed. An
environment that looks like a runner but carries no declaration is reported as misconfigured
rather than run or silently skipped."

## Related

- `2026-07-27-001` — strongest prior art: the original per-stage bias table and the wontfix resolution explaining why the simplify gate deliberately does not generalize to review stages.
- `../../plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md` — the origin decision (KTD-I / R14) that introduced `shouldRunSimplify` and chose the skip bias.
- `2026-08-20-009` — real incident showing the cost of a mutating run (20-minute apply leg killed, full revert).
- `completion-is-not-a-verdict.md` — sibling gate pattern: rendering a gate's verdict to the human; this doc covers which way a heuristic gate defaults when there is no verdict yet.
- `external-review-legs-as-unreliable-subprocesses.md` — the same "place the bias by what the error costs" reasoning applied to leg health instead of stage skipping.
- Closed issues above are bare IDs, for archaeology in git history: `2026-07-27-001`, `2026-08-20-009`.
  Both files, and the Smithers pipeline runbook this doc originally pointed at, were removed; the
  reasoning they carried is reproduced inline above.
