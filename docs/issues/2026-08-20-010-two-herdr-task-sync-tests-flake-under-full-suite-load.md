---
title: Two herdr-task-sync ordering tests flake under full-suite load
type: bug
date: 2026-08-20
status: open
---

## Why this exists

Two tests in `tests/scripts.bats` failed once during a full `bats tests/scripts.bats`
run and passed on every subsequent attempt:

- `herdr-task-sync exact socket namespaces survive legacy sanitized-name collisions`
- `herdr-task-sync orders adapter calls by inbox commit rather than invocation start`

Observed on macOS (Darwin 25.5.0), `main` at `601d749`.

Reproduction attempts:

| Command | Result |
|---|---|
| `bats tests/scripts.bats` (first run) | both fail |
| `bats tests/scripts.bats --filter 'exact socket namespaces survive legacy\|orders adapter calls by inbox commit'`, three consecutive runs | both pass every time |
| `bats tests/scripts.bats` (two later full runs) | both pass |

Both tests are about ordering and locking rather than pure formatting, which fits
a load-sensitive flake: the full suite forks many concurrent fixture processes,
and these two assert an observable ordering between them.

This is a separate test pair from the already-filed
`docs/issues/2026-08-20-002-coordinator-location-test-flake.md`, which covers the
eight-pane coordinator location test at the 1000 ms envelope boundary. The two
issues may share a root cause: all three tests assert timing or ordering under
concurrent fixture load.

## Scope

- Reproduce under load deliberately, for example by running the full suite in a
  loop or with the machine otherwise busy, and capture the failure output. The
  single observed failure was not captured in detail, which is the main gap.
- Decide whether the ordering guarantee under test is real or whether the test
  encodes a timing assumption the implementation never promised.
- If the guarantee is real, replace the timing-sensitive wait with an explicit
  barrier, as the location tests already do with
  `HERDR_TASK_SYNC_TEST_LOCATION_BARRIER`.

## Open decisions

- Whether to fold this into
  `docs/issues/2026-08-20-002-coordinator-location-test-flake.md` and treat all
  three flaky tests as one concurrency-fixture problem, or keep them separate
  until a shared cause is proven.
- Whether a flake this rare justifies work now, or should sit until it fails in
  CI where the load profile differs from a developer machine.
