---
title: "hts test teardown races a surviving engine process that recreates state/sockets, shedding hts.* tmp dirs"
short_description: "Every scripts.bats hts run can leave ${BATS_TMPDIR:-/tmp}/hts.XXXXXX dirs containing only state/sockets: hts_teardown rm -rf's HTS_WORK, but a herdr-task-sync process that outlives the test recreates the socket dir afterwards. 2490 stale dirs observed under $TMPDIR (bats debris) plus 138 under /tmp (bashunit-experiment debris); a single suite run sheds ~4-9."
type: "bug"
category: "testing-ci"
tags: ["bashunit-experiment"]
date: "2026-08-29"
status: "in-progress"
priority: "medium"
---

## Why this exists

Unbounded tmp debris accumulation on developer machines and CI; also poisons any leak-detection tooling that diffs tmp state around test runs.

## Scope

tests/helpers/herdr_task_sync.bash hts_teardown (rm -rf then no re-check), home/dot_local/bin/executable_herdr-task-sync socket-dir mkdir path. Fix direction: make hts_teardown wait for/kill surviving engine pids before removing HTS_WORK, or re-remove after a settle.

Merged in from the duplicate 2026-08-29-003 (closed 2026-08-29):

- Reproduce the teardown race (run a herdr-task-sync-heavy suite file repeatedly and diff the `hts.*` count).
- One-time cleanup guidance for the existing pile (dirs are safe to delete when no suite run is active).
- The bashunit migration (051d3de) did not move the leak: `tests/bashunit/test-dsl.bash:490` sets `BATS_TMPDIR="${TMPDIR:-/tmp}"`, so `hts_setup` still mkdtemps into the same `$TMPDIR` pile.

## Open decisions

None.
