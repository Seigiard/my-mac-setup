---
title: "Full scripts suite hangs after socket namespace test"
short_description: "Interactive macOS runs blocked before the fail-open watchdog because the test helper copied inherited TTY stdin; the helper now treats a terminal as empty input and has a bounded PTY regression."
type: "bug"
category: "testing-ci"
tags: ["herdr-task-sync","test-hang"]
date: "2026-08-24"
status: "done"
priority: "medium"
closed: "2026-08-24"
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
The same test passed immediately when invoked noninteractively with
`bats --filter`, which initially made the failure look order-dependent. The
actual difference was stdin: the full suite inherited an interactive terminal,
while the isolated invocation received immediate EOF. Sending SIGINT produced
status 130 at the call to `hts_run_fail_open_guard sleep 2` and confirmed that
only 75 of 194 tests had executed.

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

## Resolution

Fixed `hts_run_fail_open_guard` so an inherited terminal is treated as empty
test input while redirected payloads are still forwarded. Added a PTY-backed
regression that was observed red against the old helper and green after the
fix; a separate mutation proved the same test rejects discarded redirected
bytes. Verified three focused fail-open cases, two complete interactive macOS
`scripts.bats` runs with 198 passing tests, and the focused regression in
Ubuntu. The canonical `make test-ubuntu` gate remains blocked before post-apply
tests by the separate `2026-08-24-002` issue.
