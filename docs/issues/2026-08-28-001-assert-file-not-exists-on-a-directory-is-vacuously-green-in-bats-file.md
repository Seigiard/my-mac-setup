---
title: "assert_file_not_exists on a directory is vacuously green in bats-file"
short_description: "bats-file's assert_file_not_exists tests -f (regular file), so asserting absence of a DIRECTORY always passes. Two herdr-child scenarios in tests/scripts.bats (superseded watcher, sliced-wait revalidation) assert absence of a supervision run directory that in fact survives — the watcher dies via herdr-child's own set -e at watcher_generation_current's nonzero return before remove_supervision_run runs. The assertions never enforced the cleanup they describe."
type: "bug"
category: "testing-ci"
tags: ["test-integrity"]
date: "2026-08-28"
status: "in-progress"
priority: "medium"
---

## Why this exists

Found during the bats->bashunit migration experiment: a stricter -e based shim honestly failed these scenarios while bats passed them; per-scenario side-by-side comparison plus BASH_ENV xtrace of the detached watcher proved the run directory survives in BOTH runners and only the -f check hides it. Same false-confidence class as 2026-08-27-002 (bare mid-test brackets).

## Scope

Audit assert_file_not_exists / assert_file_exists call sites whose path can be a directory; switch directory expectations to assert_dir_not_exists / assert_dir_exists. A 2026-08-29 audit narrowed the count: the earlier figure (49 in scripts.bats, 3 in smoke.bats) over-counted by screening file names rather than resolving each path. Every other assert_file_not_exists path resolves to a regular file (.state, .done, .log, started/completed markers), so exactly two sites are affected, both in the migrated suite: tests/bashunit/scripts_test.sh:1344 (test 040) and :1394 (test 042). Note the paths in this issue predate commit 051d3de, which replaced tests/scripts.bats with tests/bashunit/scripts_test.sh; the defect was preserved verbatim, not fixed, and tests/bashunit/test-dsl.bash:376-396 now reimplements the -f semantics deliberately. Separately decide whether the watcher's missing supersede cleanup (run dir left behind) is a real herdr-child bug or intended, and either fix the cleanup or make the tests assert the true behavior.

## Open decisions

None.
