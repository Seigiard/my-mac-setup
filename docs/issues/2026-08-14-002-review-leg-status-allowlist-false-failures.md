---
title: Review-leg status allowlist false-fails healthy legs and forces a needless approval
type: bug
date: 2026-08-14
status: open
---

# Review-leg status allowlist false-fails healthy legs and forces a needless approval

## Why this exists

A verify-code leg is counted as failed unless its self-reported `status` string matches a fixed word list. `home/private_dot_claude/dot_smithers/workflows/lib/review-schema.ts:35`:

```ts
const TERMINAL_REVIEW_STATUS = /\b(complete|completed|done|ok|success|succeeded)\b/i;
```

`review-merge.ts:30` maps any non-matching status to `{ ok: false, findings: [] }`, and `codeReviewGate` turns a partially failed leg set into `degraded`, which parks the run for a human acknowledgement.

The status word comes from an external model's free text. It varies run to run for the same healthy outcome, so the allowlist misses words that mean success. Observed on the identical `fixture-reverse-plan` fixture:

| Run | Date | opencode leg `status` | Counted as | Run verdict |
|---|---|---|---|---|
| `run-1786539437958` | 2026-08-12 | `completed` | ok | green |
| `run-1786700241899` | 2026-08-14 | `findings` | failed | degraded, parked |

In `run-1786700241899` the opencode leg was healthy by every other measure: it returned a well-formed finding (`src/reverse.ts:2`, P3, "Unicode grapheme clusters are split during reversal", confidence 75, with a suggested fix). Its findings row is intact in `smithers.db`. Only the word `findings` in the status field made the merge discard it, drop its findings from the merged report, and park the run.

Two costs. The run stops for an approval nobody needed, which is exactly the interruption cost the dynamic-composition work is meant to remove. And the discarded leg's findings never reach the merged report, so a real P0 reported by a leg that said `findings` would be silently dropped while the run degrades for an apparently unrelated reason.

**The conservative direction is deliberate**, and the comment at `review-schema.ts:33` says so: "False-failing an exotic healthy status is the safe direction: it pauses for a human instead of passing." That reasoning holds for an unparseable or absent report. It does not hold here, where the report parsed and carried findings — the evidence of health is in the payload, not the adjective.

Unrelated and still open: in `run-1786625509762` the same leg reported a literal `failed`, which is a genuine leg failure with a different cause. This issue does not cover that.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/lib/review-schema.ts:35` — the allowlist.
- `home/private_dot_claude/dot_smithers/workflows/lib/review-merge.ts:30` — where a non-matching status discards the leg and its findings.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `codeReviewGate`, which turns the resulting partial-leg state into `degraded`.
- The same vocabulary gates doc-review legs; check whether `docReviewGate` shares the exposure.

## Open decisions

- **Judge health by payload rather than by adjective.** A report that parses and carries a `findings` array is a leg that ran. That inverts the current rule, so it needs deliberate agreement rather than a quiet patch — the fail-closed intent must survive for reports that are missing or unparseable.
- **Or constrain the leg's output** so the status field is an enum the model cannot paraphrase. The claude leg already takes a JSON schema (`reviewLegJsonSchema`); whether the opencode path can carry the same constraint needs checking.
- **Or widen the allowlist**, which is the cheapest change and the least durable: the next unseen synonym reintroduces the failure.
- Whether a leg discarded this way should still contribute its findings to the merged report, even while its status is treated as suspect.
