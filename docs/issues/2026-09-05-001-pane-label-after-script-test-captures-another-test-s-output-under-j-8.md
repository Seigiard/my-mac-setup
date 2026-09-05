---
title: "Pane-label after-script test captures another test's output under -j 8"
short_description: "The bashunit test 'herdr pane-label after script still fails a sweep that never converges' failed two of three test-macos jobs on identical trees, with a JSON MCP-server document in place of the expected sweep message, so parallel output capture rather than pane-label logic is the suspect."
type: "bug"
category: "testing-ci"
tags: ["flaky-test","parallel-execution","herdr","macos"]
date: "2026-09-05"
status: "open"
priority: "medium"
---

## Why this exists

`tests/bashunit/scripts_test.sh` runs the case `herdr pane-label after script still fails a sweep that never converges`, whose assertion is `assert_output --partial "strict pane-label sweep did not converge"`. In two consecutive `test-macos` jobs the captured output was instead a JSON document listing MCP server entries (`fff`, `executor`, `jina`, `tavily-mcp`) — output that belongs to a different case in the suite. The pane-label expectation never appeared, so the failure says nothing about sweep convergence.

Evidence that the tree is not the cause. Runs on branch `ci/brewfile-gate-head-sha`: 33946767926 failed, 33947165694 failed, 33947609695 passed. The passing run carried a tree byte-identical to the first failing run. The same case passed on `main` run 33945570715 (commit `457c1e7`) and in pull request #168. `git diff refs/pull/170/merge origin/main` reported only that pull request's own three files, none of which touch pane-label code or the post-apply suite.

The suite runs under `tests/lib/bashunit -j 8`. Output-capture crosstalk between parallel workers explains both the wrong payload and the run-to-run variation; a defect in the pane-label sweep would not substitute another case's stdout.

Impact: a required macOS job goes red on unrelated pull requests, and merging waits on a re-run. Two failures in three runs is frequent enough that re-running is not a workaround.

## Scope

- Determine how another case's stdout reaches this case's `assert_output` under `-j 8` — shared capture path, shared temporary file, or a leaked file descriptor from a backgrounded child.
- Make the capture deterministic for this case, and for any sibling that shares the same mechanism.
- Keep the case's protected behavior intact: a strict sweep that never converges must still fail, still report `strict pane-label sweep did not converge`, and still disable the plugin.
- Related but distinct, and out of scope here: `2026-09-02-013` (palette herdr-stub tests bounded by a wall-clock timeout under `-j 8`) and `2026-09-02-009` (a single `test-ubuntu` flake in the herdr-child watcher barrier).

## Open decisions

- Whether the fix belongs in the shared bashunit capture helper or in this case's own harness. Deciding needs the mechanism first.
