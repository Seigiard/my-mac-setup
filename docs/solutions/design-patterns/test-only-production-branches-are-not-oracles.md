---
title: Test-only production branches are not oracles
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - herdr
  - launchd
  - bashunit
applies_when:
  - "A production script checks a TEST_* or *_TEST_* variable only to force a failure path"
  - "A test lowers a production threshold or switches modes because the real boundary is hard to reach"
  - "A failure-path assertion passes through a hook placed immediately before the real branch"
symptoms:
  - "The test still passes if the real failure branch behind the hook is deleted"
  - "The hook's diagnostic is copied into the assertion instead of observed from the real boundary"
  - "The branch exists only in test runs and has no operator-facing behavior"
  - "A comment says the real trigger cannot be induced, but the hook remains in production code"
tags:
  - false-green
  - test-hooks
  - production-branches
  - failure-paths
  - bashunit
---

# Test-only production branches are not oracles

## Context

The test corpus audit found production scripts with branches that existed only to let tests reach a
failure path. `herdr-child` carried environment variables that skipped straight to watcher failure
states, and `morning-cleanup` carried a `TRASH_MAX_AGE_DAYS=0` branch because its test could not age
`ctime`. Those tests exercised the hook, not the shipped branch. The zero branch is gone and the
aged-removal half of the purge contract is recorded as uncovered. A real regression behind the hook
could remain green.

The fix is not to ban all test coordination in scripts. Some long-running process tests need a
barrier, pid file, or synthetic clock to stop at an otherwise tiny race window. The bad pattern is a
test-only branch that decides the verdict itself.

## Guidance

Do not add or keep a production branch whose only consumer is a test failure switch. If a script has
no production reason to read the variable, the variable cannot be the oracle.

Use one of these alternatives instead:

1. Drive the real boundary. Make the command, file operation, parser, or wrapper the script already
uses return the failure. In this repository, an `armed.state` write failure is induced by stopping the
watcher at a barrier and creating `armed.state/` as a directory. That works only because
`atomic_write` in `herdr-child-runtime.sh` refuses a directory target: plain `mv file dir/` moves the
file into the directory and exits 0, so without that guard the watcher would report itself armed and
the test would pass on the launcher's generic `watcher-unavailable` timeout instead of the
`armed-write-failed` branch it names.
2. Use synchronization-only hooks. A barrier may pause before the branch, and a pid file may expose
which process to signal, but the test must still create the failure through a real input or
side-effect.
3. Do not change the contract to make it observable. `morning-cleanup` purges by `ctime` because
a rename into the trash updates ctime and preserves the undo window; switching to `mtime` so a fixture
could be aged with `touch -t` would purge a freshly trashed old file at once. When the real clock
cannot be reached by a fixture, the branch is uncovered, and option 4 applies.
4. Delete the assertion when no independent trigger exists. Name the uncovered contract and the suite
that owns any adjacent behavior. A hook that only says "pretend this failed" is worse than no test.

## Why This Matters

A failure-path test must prove that the production branch fails safely. A test-only branch proves only
that the hook still exists. It also leaves shipped code with modes no operator can use and no runtime
contract can explain.

Synchronization hooks are narrower and safer: they expose timing, not truth. The real boundary still
decides whether the script fails, preserves state, closes a pane, or deletes a file.

## Related

- `semantic-regression-tests-over-source-shape.md` — the broader oracle gate for deciding whether a
  test is evidence.
- `source-greps-need-a-second-side.md` — the neighboring source-shape false-green pattern.
- `outliving-processes-hang-the-suite.md` — why some process tests still need barriers and pid files.
