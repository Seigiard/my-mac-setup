---
title: "Full scripts suite hangs after socket namespace test"
short_description: "On macOS, bats tests/scripts.bats stalls for more than 25 minutes when entering the fail-open deadline case after test 74, while that case passes immediately in isolation."
type: "bug"
category: "testing-ci"
tags: ["herdr-task-sync","test-hang"]
date: "2026-08-24"
status: "open"
priority: "medium"
---

## Why this exists

During the test-suite semantic cleanup, a full macOS run of
`bats tests/scripts.bats` printed tests 1 through 74 as passing, then remained
inside test 75 for more than 25 minutes:

```text
ok 74 herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions
```

Process inspection showed two nested `bats-exec-test` processes running
`herdr-task-sync fail-open deadline rejects late success before the hang guard`.
The same test passed immediately when invoked alone with `bats --filter`, so
the failure depends on prior suite state rather than the test body in
isolation. Sending SIGINT produced status 130 at the call to
`hts_run_fail_open_guard sleep 2` and confirmed that only 75 of 194 tests had
executed.

This prevents a bounded local full-suite verification and can strand CI if the
same ordering occurs there. It resembles the process/file-descriptor
contention investigated in the now-closed
`2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md`, but
the observed failure is a persistent hang rather than an assertion flake.

## Scope

- Reproduce tests 74 and 75 sequentially with process and descriptor tracing.
- Identify which process, lock, or inherited descriptor survives test 74.
- Ensure teardown terminates all owned workers before test 75 starts.
- Add a bounded regression that fails rather than hanging indefinitely.
- Verify `bats tests/scripts.bats` completes twice on macOS and in Ubuntu CI.

## Open decisions

None.
