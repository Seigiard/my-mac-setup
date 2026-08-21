---
title: Gate bias follows blast radius
date: 2026-08-21
category: design-patterns
module: se-pipeline
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

The se-pipeline (a durable Smithers workflow that runs coding agents) gained an always-present "simplify" stage that auto-edits code after the work stage (`docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md`, merged in commit `ba16224`, reachable from `main`). Because the stage mutates code and spends money on agent legs, it is not user-toggled — a heuristic gate (`shouldRunSimplify` in `home/private_dot_claude/dot_smithers/workflows/lib/stage-gate.ts`) decides per run whether the work-diff is worth a simplify pass.

That gate forced a design question every heuristic gate faces: **which way do you lean when the heuristic can't decide?** The plan's decision record (KTD-I; rationale in R14) answers it with a rule that generalizes beyond this pipeline.

## Guidance

**Set a heuristic gate's tie-breaking bias by the blast radius of the stage it guards, not by a generic preference for running or skipping.**

- A gate in front of a **mutating** stage (auto-applies edits, sends money-costing agent legs, writes anywhere) must **skip when unsure**. A wrong skip is cheap and self-describing: the code stays slightly untidy, and the next run gets another chance. A wrong run auto-edits low-value code and burns budget.
- A gate in front of a **read-only** stage (review, analysis, report-only checks) must **run when unsure**. A wrong run wastes only compute; a wrong skip silently drops a finding you will never see. The cheapest way to honor this bias is often to build no skip mechanism at all — which is what this pipeline's review stages do (see `docs/issues/2026-07-27-001-unified-stage-rightsizing-evaluator.md`, resolved wontfix: "The simplify precedent does not generalise, and that is the point").

Two implementation corollaries from the implemented gate:

1. **Layer deterministic rules before the fuzzy layer, and make every layer inherit the same bias.** `shouldRunSimplify` is a pure function over parsed `git diff --numstat` (stage-gate.ts:105-122): empty diff → clear skip; only docs/lockfile/generated/vendored/binary churn → clear skip; ≥20 substantive executable-code lines → clear run. Only the borderline middle returns `inconclusive: true` and defers to a cheap classifier (Haiku) — which per the header comment "keeps the same skip-when-unsure bias" (stage-gate.ts:6-8). The bias is a property of the whole gate stack, not of one layer.
2. **A biased skip must be loud, never silent.** The gate returns `run: false` with a human-readable `reason` naming the categories it saw (stage-gate.ts:107, 111, 119), and the pipeline reports the stage as `skipped` with that reason — per the plan, "never a silent pass" (R14).

The same bias propagates into failure handling: when the simplify stage's post-apply verification fails, the whole apply is reverted and the run degrades to "no tidy this run" (plan OQ3) — accepting a lost tidy rather than risking a bad mutation, the same lean the gate takes.

## Why This Matters

The asymmetry is real money and real code, not theory. In se-simplify run id `85e40697-1cb3-4b25-b4f6-61e17dd2d677` (2026-08-20, not a git commit), the simplify apply leg ran for its full 20-minute budget — after two report legs of 4–5 minutes each — and was then killed by the timeout, forcing a full revert: maximum spend, zero applied value (`docs/issues/2026-08-20-009-se-simplify-apply-timeout-budget.md`). That incident is what the wrong-run cost looks like even when the gate correctly said "run"; a gate that also ran on borderline diffs would pay that price for diffs with nothing to gain. The wrong-skip cost, by contrast, is invisible: slightly untidy code that the next substantive diff's run will catch.

Without a stated bias, gate authors default to symmetry ("50/50, just pick a threshold") or to run-when-unsure ("better safe than sorry") — which is exactly backwards for a mutating stage, where "sorry" is the run, not the skip.

## When to Apply

- Any time a heuristic, classifier, or threshold decides whether an **automated stage runs at all**: auto-fix passes, auto-refactor stages, codemod triggers, auto-merge bots, notification/paging triggers, expensive LLM legs.
- First classify the guarded stage: does it mutate state, spend nontrivial money, or notify humans? → skip-when-unsure. Is it report-only? → run-when-unsure.
- When writing the inconclusive branch of a layered gate (deterministic rules + classifier fallback): the fallback inherits the same bias, and the deterministic layer's "neither rule fired" result defaults to the biased outcome (see `run: false, inconclusive: true` at stage-gate.ts:117-121 — the caller may consult the classifier, but the standing answer is already "skip").
- Not a license to gate everything: the review stages here run unconditionally today; generalizing the gate to them was considered and deliberately rejected (`docs/issues/2026-07-27-001-unified-stage-rightsizing-evaluator.md`, wontfix).

## Examples

The deterministic layer, with the biased inconclusive default (`home/private_dot_claude/dot_smithers/workflows/lib/stage-gate.ts:105-122`):

```ts
export function shouldRunSimplify(files: DiffFileStat[]): SimplifyGateResult {
  if (files.length === 0) {
    return { run: false, reason: "empty diff — nothing changed to simplify", inconclusive: false };
  }
  const substantive = files.filter((f) => !isNoYield(f));
  if (substantive.length === 0) {
    return { run: false, reason: `no-yield diff — only ${describeCategories(files)} changed; ...`, inconclusive: false };
  }
  const substantiveLines = substantive.reduce((sum, f) => sum + f.linesChanged, 0);
  if (substantiveLines >= SUBSTANTIVE_RUN_THRESHOLD) {
    return { run: true, reason: `${substantiveLines} executable-code lines ... — worth a simplify pass`, inconclusive: false };
  }
  return {
    run: false,
    reason: `borderline: ... below the ${SUBSTANTIVE_RUN_THRESHOLD}-line clear-run threshold — defer to the classifier`,
    inconclusive: true,
  };
}
```

Note the shape of the inconclusive return: `run: false` **and** `inconclusive: true`. The gate does not return "undecided" — it returns "skip, unless a smarter layer overrules me", encoding the bias into the type itself.

The bias is pinned by a test, so a future edit that flips the borderline default breaks the suite (`home/private_dot_claude/dot_smithers/workflows/lib/stage-gate.test.ts:62-68`):

```ts
test("small code diff → inconclusive (defers to classifier)", () => {
  const r = shouldRunSimplify([file("src/util.ts", 4)]);
  // #then neither clear-skip nor clear-run → inconclusive, skip-when-unsure default
  expect(r.run).toBe(false);
  expect(r.inconclusive).toBe(true);
  expect(r.reason).toContain("classifier");
});
```

And the mutation-adjacent corollary — only a run that actually applied edits triggers the commit+rescan machinery (stage-gate.ts:141-144):

```ts
export function simplifyCommitDecision(status: SimplifyStageStatus, appliedEdits: boolean): SimplifyCommitDecision {
  const commit = status === "ok" && appliedEdits;
  return { commit, rescan: commit };
}
```

## Related

- `../../issues/2026-07-27-001-unified-stage-rightsizing-evaluator.md` — strongest prior art: the original per-stage bias table and the wontfix resolution explaining why the simplify gate deliberately does not generalize to review stages.
- `../../plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md` — the origin decision (KTD-I / R14) that introduced `shouldRunSimplify` and chose the skip bias.
- `../../issues/2026-08-20-009-se-simplify-apply-timeout-budget.md` — real incident showing the cost of a mutating run (20-minute apply leg killed, full revert).
- `completion-is-not-a-verdict.md` — sibling gate pattern: rendering a gate's verdict to the human; this doc covers which way a heuristic gate defaults when there is no verdict yet.
- `external-review-legs-as-unreliable-subprocesses.md` — the same "place the bias by what the error costs" reasoning applied to leg health instead of stage skipping.
- `../../se-pipeline.md` — runbook for the pipeline the gate lives in (stage order work → simplify → verify-code).
