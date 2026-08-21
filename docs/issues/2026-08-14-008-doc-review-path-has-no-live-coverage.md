---
title: "The verify-doc waive path has no live coverage since it was rewritten"
short_description: "The verify-doc waive path has no live coverage since it was rewritten"
type: "follow-up"
category: "repository-maintenance"
tags: ["repository-maintenance","follow-up"]
date: "2026-08-14"
status: "open"
priority: "low"
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

## What the live run covered

`run-1786717031730`, a fresh `make-pipeline-fixture.sh` repo launched with `se pipeline docs/plans/fixture-reverse-plan.md --doc-review --validate-cmd 'bun test'`. Verdict green, branch `se/fixture-reverse-plan-17031730`, 3,611,544 tokens, ~$2.72. Delivery was done first and checked file by file: `diff -r` over the whole `workflows` directory and the `se` launcher reported no difference between the checkout and `~/.claude/.smithers`, and the deployed copy's own suite ran 373 pass / 0 fail.

**The advisory block reached the work agent, stripped.** The run log carries the assembled prompt, and it contains the advisory header, the gate read line (`Gate read: verify-doc severity: claude maxSeverity=P2 P0=0 P1=0; opencode maxSeverity=P2 P0=0 P1=0`), and both legs' findings in full prose — the claude leg's P2 about `reverse` being unspecified for non-BMP characters is there verbatim. The whole log contains zero occurrences of `SEVERITY: {`. That absence is evidence rather than a vacuous pass: both envelope files on disk do carry the machine line, and both parsed to `maxSeverity=P2`, so the gate read it and the prompt did not.

**The per-leg severity read reached the durable notes.** `summary.notes` begins `verify-doc severity: claude maxSeverity=P2 P0=0 P1=0; opencode maxSeverity=P2 P0=0 P1=0`.

**The review-leg fix (issue `docs/issues/2026-08-14-002-review-leg-status-allowlist-false-failures.md`) was confirmed by an unforeseen synonym.** The opencode verify-code leg reported `status: "passed"` — a word that appears in no allowlist and had never been observed before. Both rules were evaluated on it:

```
status "complete": old allowlist -> ok,         new rule -> ok
status "passed":   old allowlist -> FAILED LEG, new rule -> ok
```

The merged report records `{"claude":"ok","opencode":"ok"}` and the run finished with no approval pause. Under the old rule this run would have parked for an acknowledgement nobody needed, with the opencode leg's findings dropped from the merged report — the exact defect issue 002 described, reproduced live on a status word that was not part of the original evidence.

## What the live run did NOT cover

The waive path. The verify-doc gate went green (`p0Count: 0` on both legs), so no P0 was waived, `docReviewWaiveNote` never ran, and its behaviour after the change remains unproven — specifically that the durable excerpt in `summary.notes` carries the finding without a raw `SEVERITY:` line. Unit tests cover it; no live run does.

This is the remaining scope of this issue, and it is why the issue stays open. The fixture plan is a small, well-formed feature spec, so a P0 from it is a matter of luck rather than design.

## Open decisions

- Whether the waive path deserves a deliberate trigger rather than waiting for a fixture that happens to draw a P0. A fixture plan written to provoke one would make the durable-waive-note behaviour reproducible instead of incidental.

## Reference

Unrelated but often confused with this: `docs/issues/2026-08-14-004-se-flow-stalls-after-staging-and-epilog-gaps.md` also waits on a live run. That one is about `se flow` opening a real pull request, needs a throwaway repository and an explicit operator go-ahead, and covers different code.
