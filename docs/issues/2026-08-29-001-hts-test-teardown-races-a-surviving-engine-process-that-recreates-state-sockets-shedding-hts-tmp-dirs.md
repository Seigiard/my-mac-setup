---
title: "hts test teardown races a surviving engine process that recreates state/sockets, shedding hts.* tmp dirs"
short_description: "Every scripts.bats hts run can leave ${BATS_TMPDIR:-/tmp}/hts.XXXXXX dirs containing only state/sockets: hts_teardown rm -rf's HTS_WORK, but a herdr-task-sync process that outlives the test recreates the socket dir afterwards. 2490 stale dirs observed under $TMPDIR (bats debris) plus 138 under /tmp (bashunit-experiment debris); a single suite run sheds ~4-9."
type: "bug"
category: "testing-ci"
tags: ["bashunit-experiment"]
date: "2026-08-29"
status: "done"
priority: "medium"
closed: "2026-08-30"
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

## Resolution

hts_teardown now terminates and awaits every sandbox process before removing HTS_WORK, using three ledgers: a fork-time spawn registry the engine writes under HERDR_TASK_SYNC_TEST_SPAWN_REGISTRY (test-only, with process-start tokens so recycled pids are never signalled), claim/lock owner records, and a ps scan for commands under the sandbox path (catches blocked stubs that give up tens of seconds later). Removal is then confirmed settled with a bounded recreation watch. Complementarily, the engine and harness stubs now create at most one directory level and never ancestors (atomic_write, initialize_namespace, pane dirs, sweep daemon, stub fixtures), so any straggler fails closed instead of resurrecting the deleted tree; foreground modes still bootstrap STATE_DIR recursively so fresh machines keep naming. The descriptor probe opts out of reaping because its contract requires the detached coordinator to outlive teardown. Regression test 'hts_teardown reaps a surviving engine worker before removing state' proven red on the pre-fix teardown and green after. Full -j 8 scripts_test.sh: 253 passed, 0 failed, 0 leaked hts.* dirs (previously 4-15 per run). One-time cleanup done: 3067 stale dirs moved from TMPDIR and /tmp to ~/.scratchpad/hts-pile-1788054805.
