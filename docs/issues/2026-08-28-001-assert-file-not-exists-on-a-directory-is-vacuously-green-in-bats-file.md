---
title: "assert_file_not_exists on a directory is vacuously green in bats-file"
short_description: "bats-file's assert_file_not_exists tests -f (regular file), so asserting absence of a DIRECTORY always passes. Two herdr-child scenarios in tests/scripts.bats (superseded watcher, sliced-wait revalidation) assert absence of a supervision run directory that in fact survives — the watcher dies via herdr-child's own set -e at watcher_generation_current's nonzero return before remove_supervision_run runs. The assertions never enforced the cleanup they describe."
type: "bug"
category: "testing-ci"
tags: ["test-integrity"]
date: "2026-08-28"
status: "open"
priority: "medium"
---

## Why this exists

Found during the bats->bashunit migration experiment: a stricter -e based shim honestly failed these scenarios while bats passed them; per-scenario side-by-side comparison plus BASH_ENV xtrace of the detached watcher proved the run directory survives in BOTH runners and only the -f check hides it. Same false-confidence class as 2026-08-27-002 (bare mid-test brackets).

## Scope

Audit assert_file_not_exists / assert_file_exists call sites whose path can be a directory (49 in scripts.bats, 3 in smoke.bats); switch directory expectations to assert_dir_not_exists / assert_dir_exists. Separately decide whether the watcher's missing supersede cleanup (run dir left behind) is a real herdr-child bug or intended, and either fix the cleanup or make the tests assert the true behavior.

## Open decisions

None.
