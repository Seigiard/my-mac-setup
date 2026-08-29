---
title: "Pinned bashunit carries a local patch: payload-marker result parsing"
short_description: "tests/lib/bashunit diverges from upstream 0.50.1: result parsing picks the last ##TEST_EXIT_CODE=-marked line instead of the blind last line, in aggregate_parallel_results and extract_result_counts."
type: "chore"
category: "testing-ci"
tags: ["bashunit","vendored-patch"]
date: "2026-08-29"
status: "open"
priority: "medium"
---

## Why this exists

A test's background child that inherits the captured stdout can append output after the payload line; upstream then parses garbage and reports a phantom failed test with zero failed assertions and no name (recurring anonymous test-ubuntu CI failures), or hangs when the child never exits. Red/green controls: late-child repro passed post-patch; real assertion failure and nonzero-exit test still counted failed.

## Scope

Keep the patch when re-pinning bashunit, or upstream it (github.com/TypedDevs/bashunit) and drop on a release that contains the fix. Patch sites are marked 'Local patch vs upstream 0.50.1' in tests/lib/bashunit.

## Open decisions

None.
