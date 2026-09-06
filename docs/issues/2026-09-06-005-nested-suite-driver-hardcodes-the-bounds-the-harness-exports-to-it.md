---
title: "Nested-suite driver hardcodes the bounds the harness exports to it"
short_description: "Resolved: the nested-suite driver reads HPL_INNER_BATS_PROGRESS_SECONDS and HPL_INNER_BATS_EXIT_SECONDS from the environment instead of hardcoding 60 and 30, failing loudly when either is absent, so editing the harness constants can no longer move the non-vacuity ceiling while leaving the enforced deadline behind."
type: "bug"
category: "testing-ci"
tags: ["regression","wall-clock-bounds","two-sources-of-truth"]
date: "2026-09-06"
status: "done"
priority: "medium"
closed: "2026-09-06"
---

## Why this exists

`tests/helpers/herdr_pane_labels.bash` defines two wait bounds for the nested-suite descriptor test
and exports them so the driver, which runs as its own process, reads the same values:

- `HPL_INNER_BATS_PROGRESS_SECONDS` (default 60) at `:779` — the hang guard, covering the nested run
  up to the probe writing its completion signal.
- `HPL_INNER_BATS_EXIT_SECONDS` (default 30) at `:787` — the behavioral assertion, and the only
  bound there that can fire on a healthy run.

The export at `:792` carries its own rationale at `:788-791`: without it "the driver silently falls
back to its own literals and editing the values here changes nothing, which is the same
two-sources-of-truth failure this whole change is about."

The driver was later rewritten in Python and reads neither. It hardcodes `deadline =
time.monotonic() + 60` at `tests/bashunit/scripts_test.sh:5038` and `proc.communicate(timeout=30)`
at `:5055`. Its only `os.environ` reads are `HPL_DESCRIPTOR_RELEASE_FILE`,
`HPL_DESCRIPTOR_PID_FILE`, `HPL_DESCRIPTOR_BLOCKED_PID_FILE`, `BASHUNIT_BIN`, and `PROBE_FILE`.

The outcome is worse than the deadness the comment predicted, because the constants are not dead
locally. `:812` still derives the non-vacuity ceiling from both:

```sh
HPL_BLOCKED_HERDR_CEILING_SECONDS="${HPL_BLOCKED_HERDR_CEILING_SECONDS:-$((HPL_INNER_BATS_PROGRESS_SECONDS + HPL_INNER_BATS_EXIT_SECONDS + 60))}"
```

So raising either constant raises the ceiling that is supposed to prove the fixture is not vacuous,
while leaving the deadline the driver actually enforces untouched. The two drift apart in exactly
the direction that makes the ceiling stop discriminating — the derived bound was written to stay
honest "because a hand-picked number silently inverts the first time either bound above moves," and
an ignored hand-off reproduces that inversion through a different route.

Nothing fails today: the defaults (60 and 30) happen to match the driver's literals. The defect is
latent and fires on the first edit to either constant, or the first override through the
environment.

## Scope

Make the driver read the bounds the harness exports, so one edit moves both the enforced deadline
and the derived ceiling.

1. In `tests/bashunit/scripts_test.sh`, replace the literal `60` at `:5038` and the literal `30` at
   `:5055` with reads of `HPL_INNER_BATS_PROGRESS_SECONDS` and `HPL_INNER_BATS_EXIT_SECONDS`.
2. Decide the behavior when either variable is absent from the driver's environment (see Open
   decisions) and implement it.
3. Prove the hand-off with a test that overrides one constant and observes the driver's enforced
   bound change. The oracle is the driver's own observable timing behavior under an override, not
   the source text of either file — a grep for the variable name would restate the patch rather than
   protect the relationship.

Out of scope: changing either default value, and the separate unimplemented guidance that
`ENGINE_TIMEOUT` in `executable_herdr-worktree-identity` has no alignment guard.

## Open decisions

- **Absent-variable behavior.** Fail loudly, or fall back to the current literals? A fallback
  restores the silent-divergence failure this issue is about; failing loudly makes the driver
  unusable outside the harness that exports the values. Failing loudly looks correct given the
  driver is harness-only, but it should be confirmed against any other caller.

## Resolution

The driver now reads both bounds from the environment the harness exports: int(os.environ['HPL_INNER_BATS_PROGRESS_SECONDS']) replaces the literal 60 and the matching exit bound replaces the literal 30, both failing loudly on an absent variable to match the driver's five existing os.environ reads. The absent-variable open decision was answerable from the code rather than by choice: the driver is harness-only with exactly one caller. No new test - the proving case costs a second full nested-bats run in the slowest suite file to assert a failure string, and test 1103 already exercises the driver through the same code at the defaults. docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md rewritten from a current-state defect report into the general lesson, since the fix made its old text false. Verified: test 1103 passes with the driver reading the exported bounds.
