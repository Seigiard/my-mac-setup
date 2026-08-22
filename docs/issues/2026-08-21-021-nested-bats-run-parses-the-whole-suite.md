---
title: "The nested Bats run parses all 196 tests to execute one"
short_description: "The descriptor probe now lives in tests/herdr_task_sync_descriptor_probe.bats, a one-test Bats file, while the shared hts harness lives in tests/helpers/herdr_task_sync.bash and tests/scripts.bats keeps the outer guard."
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","herdr","follow-up"]
date: "2026-08-21"
status: "done"
priority: "low"
closed: "2026-08-22"
---

## Why this exists

`herdr-task-sync bounded Bats invocation exits after detached work`
(`tests/scripts.bats`) spawns a nested Bats invocation of **its own file** to run a
single test:

```
bats tests/scripts.bats --filter '^herdr-task-sync descriptor child probe$'
```

Bats parses and gathers all 196 tests of the 5105-line file before running the one
test that survives the filter. That parse is the dominant cost and it has nothing
to do with the property under test.

Measured on a 10-core macOS host:

| What | Cost |
|---|---|
| `bats --count tests/scripts.bats` (parse alone) | 1.9 s |
| The whole nested run | 3.9 s |
| The outer test | 6.9 s |

So roughly half the nested run is parsing tests it will not execute. On the 3-core
`macos-latest` CI runner the same nested run costs about ten times more — an
inferred ≈59 s in a green run.

That cost is why the test needed a large bound at all, and it is what made the
previous single 90-second budget flake:
`docs/issues/2026-08-21-020-inner-bats-budget-flaked-the-macos-job.md`. That issue
is fixed by splitting the budget into a hang guard and an exit assertion, which
removes the load sensitivity without touching the cost. This issue is the cost.

## Why it lands after `020`, not before

A hang guard and an exit assertion have to be separate numbers at any nested-run
cost, so this work shrinks the hang guard's sizing problem but does not remove the
need for the split. Doing it first would have delayed the flake fix behind a
harness refactor.

It would, however, retire the weakest input in `020`'s analysis: the ≈59 s figure
is inferred from TAP print-order gaps in two CI logs rather than instrumented on
the runner, because under `--jobs 8` output is emitted in plan order rather than
completion order. A nested run that parsed one small file would be fast enough
that the inference stops mattering.

## Scope

- Move the `hts_*` harness out of `tests/scripts.bats` into a helper file under
  `tests/helpers/`, so the nested invocation can target a small dedicated file
  containing only the descriptor probe.
- The probe itself (`herdr-task-sync descriptor child probe`) and its
  `HTS_DESCRIPTOR_PID_FILE` skip guard move with it.
- Re-measure the nested run afterwards and resize
  `HTS_INNER_BATS_PROGRESS_SECONDS` against the new cost.

## Closed decisions

- Extracted the whole `hts_*` harness rather than only the descriptor-probe
  subset, so the main tests and the nested probe keep one shared harness.
- Landed the extraction as its own follow-up because it removes the cost that
  kept `docs/issues/2026-08-21-020-inner-bats-budget-flaked-the-macos-job.md`
  open after the budget split.

## Resolution

Extracted the herdr-task-sync harness into tests/helpers/herdr_task_sync.bash, moved the descriptor child probe into tests/herdr_task_sync_descriptor_probe.bats, and changed the bounded nested driver to target that one-test file. Verified the dedicated file count is 1, the bounded descriptor test passes, the vacuity guard still fails when it should, and bats tests/scripts.bats passes with 197 tests.
