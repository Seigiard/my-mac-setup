---
title: "Bound remaining herdr-child test barriers"
short_description: "HERDR_CHILD_TEST_TAB_CREATED_BARRIER, HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER, and HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER still poll without an owner or time bound, so a killed harness can strand test processes despite the earlier orphan-watcher fix."
type: "bug"
category: "testing-ci"
tags: ["herdr","test-isolation","process-cleanup"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-09-05"
---

## Why this exists

The earlier watcher-orphan fix bounded arm, release, and failure-publication
holds, but three harness-only waits still poll forever when their release file
is never written:

- `HERDR_CHILD_TEST_TAB_CREATED_BARRIER` in the launch path.
- `HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER` in the launch path.
- `HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER` in the continuation path.

A killed or failed harness can therefore strand the launcher or callback
process and keep a test runner's descriptors open.

## Scope

- Apply one shared owner-aware or elapsed-time bound to all three waits.
- Preserve their deterministic race boundaries and test-only status.
- Add calibrated regression coverage that omits each release signal and proves
  the process exits within the bound.

## Open decisions

- Whether launcher-side barriers should fail the launch or perform the same
  cleanup path as an interrupted launcher after their bound expires.

## Resolution

All three remaining harness-only waits now share the existing bounded hold helper watcher_hold_expired (home/dot_local/lib/herdr-child-supervision.sh), the same one the four already-bounded barriers use, so no new timeout mechanism was introduced and HERDR_CHILD_TEST_HOLD_TIMEOUT_SECONDS stays the single knob. The open decision is resolved as cleanup-then-exit-nonzero, matching every existing bounded barrier, with the cleanup chosen per barrier by what actually exists at that point in the launch: HERDR_CHILD_TEST_TAB_CREATED_BARRIER runs cleanup_pane test-barrier-expired, because only the freshly created tab and its root pane exist there and that is exactly what the adjacent token-write-failure path and the interrupted launcher both run; HERDR_CHILD_TEST_LAUNCH_POST_ARM_BARRIER runs the new preserve_launched_child helper, because the watcher is armed over a live child by then and closing the pane would kill real work. That helper is an extraction of launch_signal_handler's existing preserve-and-abort body, leaving launch_signal_handler as a thin wrapper adding only the signal exit-status mapping and the in-flight prompt kill, so signal behavior is unchanged. HERDR_CHILD_TEST_CALLBACK_RECEIPT_BARRIER deliberately leaves the in-progress claim in place and exits 1, because that is precisely the state a killed owner leaves and supervision already expires it into callback-owner-lost; writing failed would have misreported a parent delivery that had in fact succeeded. Verified independently of the worker on macOS. The oracle is the OS process table, not file content: each test captures the child PID from $! and requires the process to leave the table within a bound. Three separate mutations, each confirmed present in the file before running and each isolated to one barrier, each turned exactly its own test red with the process-table timeout rather than an assertion on output: tab-created (herdr-child-launch.sh:249), post-arm (herdr-child-launch.sh:581), callback-receipt (herdr-child-continuation.sh:336). The pre-existing signal-handler tests that guard the refactored path stay green, as does test 059, which parks the callback owner at one of these barriers and SIGKILLs it. Happy-path tests 033, 049 and 066 that park at a barrier and then release still pass at the default 120s bound; only the three new tests lower the bound, and they pass it inline via env so no neighbouring test inherits it. make lint clean, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh 346 passed 1 pre-existing platform skip 0 failed 1807 assertions, make test-issues 58 tests OK, make test-local exit 0 with both changed libraries mapping to their expected destinations.
