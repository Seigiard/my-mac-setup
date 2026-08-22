---
title: "The nested Bats run parses all 196 tests to execute one"
short_description: "The descriptor test spawns a nested Bats invocation of its own 5105-line file to run one filtered test, so roughly half that run is parsing tests it will never execute -- which is why the bound around it had to be large at all."
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","herdr","follow-up"]
date: "2026-08-21"
status: "open"
priority: "low"
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

## Open decisions

- Whether to extract the whole `hts_*` harness or only the subset the probe needs.
  Extracting only a subset risks the two copies drifting; extracting the whole
  harness is a large, mostly mechanical move across a 5105-line file that many
  other tests depend on.
- Whether the extraction is worth doing on its own, or only as part of a broader
  split of `tests/scripts.bats` — the file's size is the underlying condition, and
  this test is one symptom of it.
