---
title: "macOS scripts_test.sh flakes under -j 8 across unrelated cases"
short_description: "Four of five test-macos jobs on one branch failed tests/bashunit/scripts_test.sh on trees that differ only in unrelated files, in two distinct cases and with two distinct symptoms — another case's JSON in place of the expected output, and a temp file that does not exist yet — while test-ubuntu passed every time, so the suite's parallel execution on macOS is the suspect rather than the herdr behavior under test."
type: "bug"
category: "testing-ci"
tags: ["flaky-test","parallel-execution","herdr","macos"]
date: "2026-09-05"
status: "open"
priority: "high"
---

## Why this exists

`tests/bashunit/scripts_test.sh` runs in the post-apply suite under `tests/lib/bashunit -j 8`. On branch `ci/brewfile-gate-head-sha` its `test-macos` job went red in four of five runs, in two unrelated cases, on trees that differ only in files neither case reads. The `test-ubuntu` job passed every time.

| Run | Result | Case | Symptom |
|---|---|---|---|
| 33946767926 | fail | `herdr pane-label after script still fails a sweep that never converges` | `assert_output --partial "strict pane-label sweep did not converge"` saw a JSON document of MCP server entries (`fff`, `executor`, `jina`, `tavily-mcp`) — output belonging to a different case |
| 33947165694 | fail | same case | same symptom |
| 33947609695 | pass | — | tree byte-identical to run 33946767926 |
| 33948544900 | fail | `herdr-child detached delivery retries temporary parent blockage and prompt transport failure` | `scripts_test.sh:2989` — `grep` exited 2 on `$TMPDIR/.../successful-prompts.log`: "No such file or directory" |
| 33948914983 | fail | pane-label case again | same JSON-substitution symptom, third occurrence |

Two symptoms, one setting. A case reading another case's stdout points at shared output capture; a missing temp file points at a wait that returns before a background writer has created it. Both are properties of how the suite runs in parallel, not of the herdr behavior under test.

Evidence that the branch's own diff is not the cause. The passing run carried a tree byte-identical to the first failing run. `git diff refs/pull/170/merge origin/main` reported only that pull request's own files: a CI workflow step, `tests/test_ci_workflow.py`, an issue record, and a Brewfile comment. None is read by either failing case. The same `scripts_test.sh` passed on `main` run 33945570715 (commit `457c1e7`) and in pull request #168.

Impact: a required macOS job goes red on unrelated pull requests and merging waits on a re-run. At four failures in five runs, re-running is not a workaround; it is what merging currently depends on.

## Scope

- Identify the mechanism behind each symptom: how one case's stdout reaches another case's `assert_output`, and why the herdr-child case proceeds before `successful-prompts.log` exists.
- Determine whether both share one root cause in the suite's parallel harness or need separate fixes.
- Make both cases deterministic at `-j 8` without weakening what they protect: the strict sweep must still fail and report `strict pane-label sweep did not converge`, and the detached-delivery case must still prove the retry after parent blockage.
- Check the rest of `scripts_test.sh` for the same pattern once the mechanism is known, rather than patching only the two observed cases.
- Related but distinct, and out of scope here: `2026-09-02-013` (palette herdr-stub tests bounded by a wall-clock timeout at `-j 8`) and `2026-09-02-009` (a single `test-ubuntu` flake in the herdr-child watcher barrier). If the mechanism found here explains either, fold them in then.

## Open decisions

- Whether the fix belongs in the shared bashunit capture and wait helpers or in each case's own harness. Deciding needs the mechanism first.
