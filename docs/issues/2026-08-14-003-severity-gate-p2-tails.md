---
title: Severity-gate P2 tails — stripSeverityLine over-matching, raw SEVERITY in waive excerpts, untested wiring
type: follow-up
date: 2026-08-14
status: open
parent-plan: docs/plans/2026-07-24-002-feat-verify-doc-blocking-gate-plan.md
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

## Reference

Severity parsing and stripping: `home/private_dot_claude/dot_smithers/workflows/lib/severity-summary.ts` with unit tests in `severity-summary.test.ts`. Consumer wiring: `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`. The gate's design (P0 blocks, lower severities pass with a waive trail) comes from the verify-doc blocking-gate plan named in `parent-plan`.
