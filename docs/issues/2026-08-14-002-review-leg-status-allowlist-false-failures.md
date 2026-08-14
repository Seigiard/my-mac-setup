---
title: Review-leg status allowlist false-fails healthy legs and forces a needless approval
type: bug
date: 2026-08-14
status: done
closed: 2026-08-14
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

## Resolution

The first option was taken: health is judged by payload, not by adjective. `isUsableReviewLegStatus` in `home/private_dot_claude/dot_smithers/workflows/lib/review-schema.ts` replaces the success allowlist at the merge call site.

The new rule, in order:

1. A status that is missing, non-string, or empty fails the leg. This is where the fail-closed intent survives: no evidence is not health.
2. A negated success word ("not completed") fails the leg. Plain containment would have read `completed` and passed it.
3. A known success word passes.
4. An explicit failure or progress state fails: `failed`, `error`, `crashed`, `timed out`, `pending`, `queued`, `running`, `in_progress`, `waiting`, `incomplete`, `partial`, `unknown`. A failure word under a negation ("no errors", "0 failures") does not count as one.
5. Anything else passes, because the caller has already required a parsed `findings` array — that array is the evidence the leg ran.

Two details that are easy to get wrong and are now covered by tests. Underscores are word characters, so `\bwaiting\b` does not match `waiting_for_reviewers` — the exact status this vocabulary exists to catch. Separators are normalised to spaces before any word-boundary test. And negation is checked in both directions, because containment alone flips the verdict either way.

The third open decision is answered by consequence: a leg whose status is merely unrecognised now contributes its findings, since it counts as healthy. A leg that says it failed contributes nothing, which is unchanged — a dead leg's partial findings are not evidence.

The doc-review exposure named in the Scope section does not exist. `docReviewGate` reads `claudeStatus`/`opencodeStatus`, and those are computed in code (`se-doc-review.tsx:179`: `claudeReview ? "ok" : "failed"`), never taken from a model's free text. No model-chosen word reaches that gate.

Verified against the recorded run rather than only by unit test. The legs of `run-1786700241899` were replayed out of `smithers.db` through the merge, before and after the change:

```
BEFORE: merged legs {"opencode":"failed","claude":"ok"}  merged findings: 0
        gate: would park for approval (opencode)
AFTER:  merged legs {"opencode":"ok","claude":"ok"}      merged findings: 1
          P3 src/reverse.ts:2 — Unicode grapheme clusters are split during reversal [opencode]
        gate: no leg failed — no approval pause
```

The second line is the part that mattered more than the pause: before the fix the leg's finding was dropped from the merged report entirely. A P0 reported by a leg that said `findings` would have vanished while the run degraded for an apparently unrelated reason.

Suite: 360 pass / 0 fail, including the existing test that `waiting_for_reviewers` is still discarded. The genuine leg failure noted above (`run-1786625509762`, literal status `failed`) is still counted as a failure.
