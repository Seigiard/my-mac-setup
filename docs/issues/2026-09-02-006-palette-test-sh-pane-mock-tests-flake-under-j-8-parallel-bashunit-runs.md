---
title: "palette_test.sh pane-mock tests flake under -j 8 parallel bashunit runs"
short_description: "Three palette_test.sh tests intermittently fail under 'tests/lib/bashunit -j 8' with 'Could not read pane w1:p1' errors from the pane mock; the same tests pass reliably at -j 1 and the pattern reproduces on main without this branch's changes, so it is pre-existing test-infrastructure flakiness rather than a regression."
type: "bug"
category: "testing-ci"
tags: ["palette","flaky-tests","bashunit"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Running 'tests/lib/bashunit -j 8 tests/bashunit/palette_test.sh' intermittently fails 3 tests around lines 840, 855, and 967 (R6/R9-area pane-run and report-metadata tests) with output like 'Could not read pane w1:p1, so Run there was not run.' and 'cat: .../overlay/herdr.log: No such file or directory'. Rerunning the identical command with -j 8 immediately after often passes clean (57 passed, 1 pre-existing risky, 194 assertions). A single-threaded run ('-j 1') passed clean as well. Confirmed via 'git stash' that the same failure pattern reproduces on main (commit b632c34) with none of this branch's edits applied, so this is pre-existing test-harness flakiness, not something introduced by docs/issues/2026-09-02-003. Suspected cause: the pane-mock fixture these tests share (pane id w1:p1, an overlay/herdr.log file under a per-test PALETTE_WORK tmp dir) has state that is not fully isolated or not fully synchronized before assertion under -j 8 parallel worker contention.

## Scope

Reproduce the flake deterministically (loop 'tests/lib/bashunit -j 8 tests/bashunit/palette_test.sh' several times, capture the failing run), identify which pane-mock fixture setup is shared or racy across the three failing tests, and either isolate the fixture per test or serialize the tests that depend on it. Verify with repeated -j 8 runs (aim for N consecutive clean runs) before closing.

## Open decisions

Whether the fix is per-test fixture isolation, a serialization directive for this test group, or a fix to the underlying pane-mock helper; investigate before deciding.
