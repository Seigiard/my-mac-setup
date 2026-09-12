---
title: "Build and tune cross-model test evidence review"
short_description: "Implement a repo-owned se-test-evidence-review skill that runs an independent read-only Sonnet/Terra External leg pair over changed test evidence, tunes a structured findings contract against hidden-label historical Git diffs, and joins se-code-review only when it adds confirmed signal without false positives."
type: "follow-up"
category: "se-pipeline"
tags: ["tests","code-review","external-leg","semantic-tests","agent-skills"]
date: "2026-09-06"
status: "open"
priority: "high"
---

## Why this exists

The repository's testing standard requires a Test oracle independent of the files a change edits.
A test can still look substantial while providing no independent evidence: its expected value may
come from the same patch, its mocks may bypass the production branch named by the test, or it may
reimplement the production rule and reproduce the same defect. Weak assertions and tests coupled to
implementation shape create the same false confidence.

The retired `test-oracle-guard` hook could inspect only one proposed edit fragment. It could not compare
the test with the rest of the diff without breaking the pure, no-I/O policy contract, so the repository
deliberately moved this class to review. `se-code-review` currently appends one tautology criterion when
the upstream `testing` persona is selected, and its apply stage requires an oracle line before writing a
requested test. The upstream persona now also checks mirror tests, weak assertions, overmocking,
implementation coupling, and behavior-insensitive tests. These overlapping checks are useful, but they
do not provide a separately measurable audit of test evidence or a structured account of oracle
provenance and counterfactual defects.

Historical audits provide real calibration material. Confirmed failures include a test that pinned an
overridable `-j 8` default, revision tests whose injected snapshot bypassed the production Git branch,
an alias expectation computed by the same helper as the value under test, and a protocol fake that
reimplemented Herdr semantics. The previously cited Ghostty incident was disproved by repository history
and must remain a false-lead control rather than positive evidence.

External prior art supports a dedicated audit boundary but is not a drop-in implementation. The
`kant13/spec-review` project keeps quality principles as a reference owned by its review skill;
`gjalla-test-audit` covers tautological and reimplemented tests; and SecondSky's
`test-quality-analysis` and `mutation-testing` cover weak evidence and mutation probes. Their useful
ideas must be distilled into this repository's language-neutral, read-only contract rather than copied
as framework-specific workflows. The `gjalla/engineering` material requires particular copying caution
because that repository exposes no license.

## Scope

### 1. Implement the standalone review

- Add the repository-owned `se-test-evidence-review` skill, its Claude symlink adapter, and its reserved
  global skill name. Its ordinary input follows the review target vocabulary already used by
  `se-code-review`: current diff, explicit base, branch, or pull request.
- Keep the complete workflow read-only. It may inspect the diff, related production code, tests,
  fixtures, and mocks, but it neither edits files nor runs tests or mutation tooling.
- Before paying for the pair, return not-applicable when the reviewed diff has no added or changed test,
  fixture, or mock surface. Production behavior changed without tests remains owned by the upstream
  `testing` persona.
- Run one Claude leg and one OpenCode leg through `se-external-leg-pair`. Use its current fixed
  Sonnet/high and Terra launch policy for the first implementation; semantic model selection belongs to
  `2026-09-12-001` and does not block this trial.
- Preserve the External leg pair contract: two valid distinct reports provide paired coverage; one
  valid report degrades to single-source coverage; byte-identical reports are `indeterminate-single`,
  never consensus; no valid report fails this audit; incomplete cleanup forbids synthesis.
- Return a test-specific JSON report. Each finding requires one primary `category`, optional additional
  `signals`, the test file and line, claimed behavior, oracle source and independence judgment, a
  realistic counterfactual defect, code-grounded evidence, severity, and anchored confidence.
- Use these primary categories: `same-patch-oracle`, `reimplemented-production-logic`,
  `mock-only-evidence`, `weak-assertion`, `implementation-coupling`, and
  `regression-insensitive`. Merge overlapping symptoms into one finding rather than reporting category
  duplicates. `same-patch-oracle` covers both positive assertions copied from a changed artifact and
  negative assertions such as `assert_not_contains`, `refute_match`, or `! grep` that have no independent
  oracle.
- Return findings and residual risks only; do not inventory clean tests. Findings are report-only even
  when they propose a concrete correction.
- Add `references/test-evidence-principles.md` and the smallest supporting references needed for the
  schema and oracle analysis. Write the guidance in the repository's vocabulary, include source
  provenance for `kant13/spec-review`, `gjalla-test-audit`, SecondSky `test-quality-analysis`, and
  SecondSky `mutation-testing`, and copy only material whose license permits it. Mutation guidance is a
  thought experiment: name a defect that should turn the test red, never execute the mutation.
- State the review's visibility limit: a branch diff cannot establish the provenance of a value whose
  source exists only outside that diff. Uncertainty becomes a residual risk, not a fabricated finding.

The first release does not own missing tests, untested branches, flakiness, nondeterminism, naming or
style, coverage percentages, real mutation execution, or whole-suite audit. Those remain with existing
review and testing workflows.

### 2. Build the benchmark and tune the skill

- Treat session history as discovery evidence only. Run each case in an isolated historical Git
  worktree at the post-change commit with its parent or named base as the review range. Do not expose
  issue text, session transcripts, gold labels, or benchmark metadata to the reviewed agent.
- Seed positive cases from the verified ranges `dbffb66..051d3de`, `806a775..3eea07d`,
  `cfe2e40..68d8894`, and `d0bb59d..d080d31`. Seed clean controls from
  `9c1416f..a492251`, `a492251..703c83a`, and `703c83a..e5e671b`. Search session and Git history for
  further independently adjudicated cases before freezing the corpus. Exclude the disproved Ghostty
  account as a positive case.
- Give every positive label an independent basis: a prior human review, repository issue, or recorded
  mutation result. Pair bad and repaired states where history permits.
- Freeze separate tuning and holdout sets. Tuning agents must not see holdout labels. Keep the evaluator
  immutable during prompt experiments; publish the consumed holdout and final results under
  `docs/benchmarks/` after the run, then require fresh holdout cases for a later tuning cycle.
- Establish the actual current `se-code-review` workflow as baseline on the same ranges and models.
  Run baseline and candidate three times per case to measure model variance.
- Tune the skill and its references only after the initial implementation works end to end. Persist each
  experiment and measurement before proceeding so the optimization can resume without conversation
  history.
- Pass the trial only when every confirmed HIGH defect is found in at least two of three runs, paired
  clean controls produce no confirmed false positives, at least one confirmed finding is consistently
  missed by baseline, and every report validates against the test-specific JSON schema. Record latency
  and cost as diagnostics, not initial gates.

### 3. Integrate only after the measured gate

- When the trial passes, make `se-code-review` run Test evidence review only for a diff that adds or
  changes tests, fixtures, or mocks, then run its ordinary Code review. Do not feed audit findings into
  the ordinary peer prompts; merge and deduplicate both result sets only after both independent passes
  finish.
- Replace the wrapper's appended `Tautological tests considered harmful` criterion with the dedicated
  audit. Keep the apply-time oracle gate for any finding that requests a new test.
- If the audit loses both legs, continue ordinary Code review and report the missing test-evidence
  coverage explicitly rather than presenting a clean combined pass. Preserve the ordinary review's own
  failure semantics.
- If the trial fails any acceptance gate, leave `se-test-evidence-review` available for explicit use and
  do not add it to automatic Code review.

## Open decisions

None. The standalone boundary, read-only scope, pair degradation, findings contract, benchmark gate,
and conditional integration behavior were accepted during design.
