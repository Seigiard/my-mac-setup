---
title: "Pinned bashunit carries a local patch: payload-marker result parsing"
short_description: "tests/lib/bashunit diverges from upstream 0.50.1: result parsing picks the last ##TEST_EXIT_CODE=-marked line instead of the blind last line, in aggregate_parallel_results and extract_result_counts."
type: "chore"
category: "testing-ci"
tags: ["bashunit","vendored-patch"]
date: "2026-08-29"
status: "done"
priority: "medium"
closed: "2026-08-29"
---

## Why this exists

A test's background child that inherits the captured stdout can append output after the payload line; upstream then parses garbage and reports a phantom failed test with zero failed assertions and no name (recurring anonymous test-ubuntu CI failures), or hangs when the child never exits. Red/green controls: late-child repro passed post-patch; real assertion failure and nonzero-exit test still counted failed.

## Scope

Keep the patch when re-pinning bashunit, or upstream it (github.com/TypedDevs/bashunit) and drop on a release that contains the fix. Patch sites are marked 'Local patch vs upstream 0.50.1' in tests/lib/bashunit.

## Open decisions

None.

## Resolution

The patch stays vendored and is now regression-guarded instead of upstreamed: upstreaming to TypedDevs/bashunit remains possible later, but the repo needs protection against a silent re-pin today. Added tests/bashunit/bashunit_late_output_probe_test.sh, a deterministic late-child repro (the child waits for the test subshell to die via a bash-3.2-safe pid probe, then appends output after the payload line on the inherited capture), and tests/bashunit/scripts_test.sh test scripts_259, which runs the probe through the real pinned runner in parallel and sequential modes. Calibrated both states: green on the patched runner; against a de-patched copy (both 'Local patch vs upstream 0.50.1' sites reverted to the blind last-line read) the parallel leg reports a phantom failed test (exit 1) and the sequential leg zeroes the assertion count - both flip scripts_259 red. make test-suite passes with verdict parity to the clean baseline; python3 scripts/check_bats_assertions.py tests is clean.
