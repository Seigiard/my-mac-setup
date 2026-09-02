---
title: "test-oracle-guard misses positive tautological tests"
short_description: "The shared guard engine denies only negative-assertion patterns, so the 2026-09-02 ghostty-shortcuts incident's positive tests with expected values from the same patch passed all three client hooks silently; extending it needs a low-false-positive signal such as requiring an oracle: comment on new test functions."
type: "follow-up"
category: "testing-ci"
tags: ["test-oracle","hooks"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

The shared engine `home/dot_local/bin/executable_test-oracle-guard` fires only on negative-assertion patterns (`assert_not_contains`, `refute_match`, `! grep`, ...). In the 2026-09-02 ghostty-workspace-shortcuts session, an agent added two positive tests to `tests/bashunit/palette_test.sh` whose expected values (new command-kind names) came from the same patch that introduced them — the textbook tautology the CLAUDE.md gate forbids — and all three client hooks (Claude Code, OpenCode, Pi) stayed silent because no negative pattern was present. Prose alone did not stop it; the enforcement layer has a structural blind spot.

## Scope

Extend the engine with a low-false-positive signal for positive tautologies, or explicitly decide the class stays prose-only. Candidate mechanism: require an `oracle:` comment within N lines above every *new* test function in a proposed edit (the existing escape-hatch convention, applied at function granularity instead of only on flagged negative lines). Weigh blast radius per `docs/solutions/design-patterns/gate-bias-follows-blast-radius.md` — this would touch every new test in every repo across all three clients. Update the three thin adapters only if the engine's stdin/argv contract changes.

## Audit result (2026-09-02)

A repository-wide audit for positive tautologies ran over all ~600 tests in
`tests/` — the four bashunit suites, the five Python suites, the two Bun
suites, and the shared helpers.

**The incident this issue cites did not happen as recorded.** No commit on any
ref adds the two positive tests to `tests/bashunit/palette_test.sh` described
above, and no version of that file or its `tests/palette.bats` ancestor has
ever contained the string `ghostty`. The closest real match is
`test_palette_058`/`059`, whose expected values (`"New worktree"`,
`worktrunk.open`, `worktrunk.remove`, `worktrunk.merge`) did come from the
`commands.toml` entries added in the same patch — the exact tautology shape —
and which `4adc681` deleted on 2026-09-02. Nothing matching the description
survives in the file. The engine extension is therefore the only live item
here; the incident is not evidence for it.

**The audit is evidence, though, and it argues against the candidate
mechanism.** Two HIGH findings were confirmed by mutation, and neither would
have been caught by requiring an `oracle:` comment on every new test function,
because both were written *with* a plausible oracle in mind:

- `tests/test_post_apply_suite_contract.py` pinned `-j 8`, a production
  default that `tests/run-post-apply.sh` explicitly declares overridable. The
  test was red under `MMS_BASHUNIT_JOBS=4` — the value CI's own macOS job sets
  since `c029819` — and blind to the wrapper dropping the operator's cap.
- `tests/pi-brew-auto-update.test.ts` named two tests for git-revision
  behavior while injecting `snapshotExtensions` wholesale, so the production
  git branch never ran. Blinding `captureExtensionSnapshot` to every
  git-installed extension left all 27 tests green.

The rest of the corpus yielded no further HIGH findings: about twenty
MEDIUM/LOW restatements, mostly an expected value transcribed from the
artifact under test while a stronger neighbour already owned the contract.
Against that base rate, a mandatory `oracle:` comment on every new test
function in every repo across all three clients is high friction for a signal
that missed both real failures. Per
`docs/solutions/design-patterns/gate-bias-follows-blast-radius.md`, the blast
radius does not justify it.

What the audit suggests instead, in decreasing confidence: a check that fires
when a test's expected literal also appears in a non-test file changed by the
same patch (narrow, needs the diff the stateless hook does not have today),
and treating "no mutation proof" rather than "no oracle comment" as the
reviewable gap — every fix in this audit carried one.

## Open decisions

**Superseded in part.** The question of whether `oracle:` on every new test
function is acceptable friction is answered no by the evidence above. What
remains open is whether the engine should gain a diff-aware positive check at
all, given that it would need session or patch state the stateless hook does
not have, or whether the positive class stays prose-plus-review.
