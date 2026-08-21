---
title: "Severity-gate P2 tails — stripSeverityLine over-matching, raw SEVERITY in waive excerpts, untested wiring"
short_description: "Severity-gate P2 tails — stripSeverityLine over-matching, raw SEVERITY in waive excerpts, untested wiring"
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","follow-up"]
date: "2026-08-14"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-07-24-002-feat-verify-doc-blocking-gate-plan.md"
closed: "2026-08-14"
---

# Severity-gate P2 tails — stripSeverityLine over-matching, raw SEVERITY in waive excerpts, untested wiring

## Why this exists

The se-pipeline severity gate (parsing `SEVERITY:` lines from review-leg reports and driving the P0 blocking decision) works on the happy path but carries three known P2 gaps. They were noted at implementation time and deferred; nothing tracks them in code.

## Scope

1. **`stripSeverityLine` can eat legitimate prose.** `home/private_dot_claude/dot_smithers/workflows/lib/severity-summary.ts:72` strips any line that looks like a severity marker. A finding whose prose genuinely starts with `SEVERITY:` is silently truncated.
2. **Waive excerpts can leak a raw `SEVERITY:` line.** The excerpt shown when a finding is waived may include the unstripped marker line, confusing the reader (and any downstream parser of the excerpt).
3. **Pipeline wiring of severity/waive has no tests.** `severity-summary.ts` itself is tested (`severity-summary.test.ts`), but the wiring in `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` that consumes it — severity extraction into gate decisions and waive flow — is not covered.

## Open decisions

- Whether `stripSeverityLine` should anchor on position (only the first line of a finding) or on a stricter grammar, instead of matching anywhere.
- Whether waive excerpts should be built from the already-stripped text (likely yes; decide where the strip belongs).

## Resolution

All three gaps are closed.

**1. `stripSeverityLine` no longer eats prose.** It now removes a line only where the machine line actually lives — the protected slot `parseSeveritySummary` reads: the last non-empty line before the terminal `Review complete`, or the last non-empty line when the envelope has no terminal line. Both open decisions were taken together rather than one of them: position alone is not enough, because prose can land in the slot too, so the line must also carry a JSON object after the prefix. Between the two remaining failure modes, letting a malformed machine line through is noise in a prompt, while eating a prose line loses review content the work agent needed.

**2. Waive excerpts are built from stripped text.** `docReviewWaiveNote` strips before it cuts to the 800-character cap. The machine line already appears in the same note as a parsed per-leg label (`maxSeverity=P0 P0=1 P1=0`), so repeating it raw confused the reader and any parser of the note.

**3. The wiring is tested.** `readDocReviewAdvisory`, `docReviewWaiveNote`, `docReviewSeverityStatusNote` and `legSeverityLabel` moved from `se-pipeline.tsx` into `home/private_dot_claude/dot_smithers/workflows/lib/doc-review-notes.ts`, with `doc-review-notes.test.ts` covering them: the strip in both directions, the waived-run wording, a dead leg versus a leg whose summary did not parse, and the fail-soft path when tmp-cleanup already removed an envelope. Ten tests; the suite is 373 pass / 0 fail.

The move was made now because it changes `se-pipeline.tsx`'s statically-imported module graph, which invalidates a parked run's resume (KTD1). `se list` showed no run in `running` or `waiting-approval` first — the same precondition issue 005 was waiting on.

The prompt text was moved verbatim, and that was checked rather than assumed: the advisory header and the waive paragraph handed to the work agent are byte-identical to the pre-move versions, diffed out of `git show HEAD`. A silently reworded prompt changes agent behaviour without changing any test.

The module declares its own structural `DocReviewLegs` interface instead of importing the workflow's zod type, so the library has no dependency back on the workflow file.

## Reference

Severity parsing and stripping: `home/private_dot_claude/dot_smithers/workflows/lib/severity-summary.ts` with unit tests in `severity-summary.test.ts`. Consumer wiring: `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`. The gate's design (P0 blocks, lower severities pass with a waive trail) comes from the verify-doc blocking-gate plan named in `parent-plan`.
