---
title: The verify-doc advisory and waive path has no live coverage since it was rewritten
type: follow-up
date: 2026-08-14
status: open
---

# The verify-doc advisory and waive path has no live coverage

## Why this exists

Two changes landed today in the se-pipeline review path, and neither has been exercised by a live run. Both are proven by unit tests and by replaying recorded data through pure functions. Neither has been proven by the pipeline actually running.

**Commit `3d28f09` — severity-gate tails (issue `docs/issues/2026-08-14-003-severity-gate-p2-tails.md`).** `readDocReviewAdvisory`, `docReviewWaiveNote`, `docReviewSeverityStatusNote` and `legSeverityLabel` moved out of `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` into `home/private_dot_claude/dot_smithers/workflows/lib/doc-review-notes.ts`, and `stripSeverityLine` changed from prefix-matching anywhere to matching the protected slot only.

These functions run only when the verify-doc stage runs, which means a launch carrying `--doc-review`. The fixture regression in section 5 of `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` does not pass that flag, so re-running it would not touch this code. There is no live evidence at all: not that the advisory block reaches the work prompt, not that a waived P0 produces its durable note, not that the stripped envelope still carries its findings.

**Commit `186b6a8` — review-leg status judged by payload (issue `docs/issues/2026-08-14-002-review-leg-status-allowlist-false-failures.md`).** The legs of `run-1786700241899` were replayed out of `smithers.db` through `mergeReviewReports`, which proved the merge behaviour. The path from a persisted `review_leg` row to that call site inside the running workflow was not exercised.

**Delivery is also outstanding.** `~/.claude/.smithers` still holds the code from before both commits, so nothing described here is live yet. The runbook's file-by-file check after `chezmoi apply` (`diff -r <source>/workflows ~/.claude/.smithers/workflows`, never `chezmoi diff` on the directory) has not been run for these files.

## Scope

One fixture pipeline run with plan review enabled covers both changes at once:

```
tests/fixtures/make-pipeline-fixture.sh
cd <fixture-dir> && se pipeline docs/plans/fixture-reverse-plan.md --doc-review --validate-cmd 'bun test'
```

Cost is higher than the plain regression because the verify-doc stage adds two external review legs: roughly $2-3 and 40-60 minutes, against ~$1.50 for the run without the flag.

What to check when it finishes, beyond a green verdict:

- The work stage's prompt contains the advisory block, and the machine `SEVERITY:` line is absent from it while the legs' findings are present. The envelopes are under the run's report directory, named in `se show <runId>`.
- `summary.notes` carries the per-leg severity read (`verify-doc severity: claude …; opencode …`).
- If the verify-doc gate goes red on a parsed P0 and the operator approves, the waive note lands in `summary.notes` with an envelope excerpt that has no raw `SEVERITY:` line. A clean fixture may not produce a P0, in which case the waive half stays uncovered and should be said so rather than assumed.
- Every review leg is counted `ok` unless it genuinely failed — the defect issue 002 fixed showed up as a needless approval pause with the leg's findings missing from the merged report.

Preconditions: no run in `running` or `waiting-approval` (`se list`), because both commits change `se-pipeline.tsx`'s statically-imported module graph and a parked run's resume would be invalidated (KTD1).

## Open decisions

- Whether the waive path deserves a deliberate trigger rather than waiting for a fixture that happens to draw a P0. A fixture plan written to provoke one would make the durable-waive-note behaviour reproducible instead of incidental.

## Reference

Unrelated but often confused with this: `docs/issues/2026-08-14-004-se-flow-stalls-after-staging-and-epilog-gaps.md` also waits on a live run. That one is about `se flow` opening a real pull request, needs a throwaway repository and an explicit operator go-ahead, and covers different code.
