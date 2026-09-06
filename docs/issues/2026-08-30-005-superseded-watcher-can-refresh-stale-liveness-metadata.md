---
title: "Superseded watcher can refresh stale liveness metadata"
short_description: "refresh_supervision_liveness publishes supervised=<old-generation> without an under-lock generation precondition, so a watcher already in the refresh path can update stale liveness after a managed takeover."
type: "bug"
category: "herdr"
tags: ["concurrency"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-09-05"
---

## Why this exists

`watch_child` checks `watcher_generation_current` after a sliced `herdr agent wait`, then calls `refresh_supervision_liveness` separately. The refresh uses unconditional `metadata_report`, unlike failure publication's generation-checked `metadata_report_if_generation`. A managed continuation can publish its new generation after the watcher check but before the refresh acquires the pane metadata lock, allowing the old watcher to publish a newer `supervised=<old-generation>` label over the active generation.

The neighboring sliced-wait regression only changes the generation before `watcher_generation_current`; it does not place takeover between that check and publication. Metadata sequence serialization therefore does not close this race because the stale refresh can legitimately receive the later sequence.

## Scope

Publish liveness through `metadata_report_if_generation` so generation, terminal, and session identity are revalidated while holding the per-pane metadata lock. Add a barrier-driven semantic regression that pauses the old watcher after its ordinary generation check, completes a managed takeover, then proves the old generation cannot publish liveness.

## Open decisions

None.

## Resolution

refresh_supervision_liveness now takes run_dir and publishes through metadata_report_if_generation instead of the unconditional metadata_report, so generation, terminal, and session identity are revalidated while holding the per-pane metadata lock, exactly like the failure path. All six call sites were converted (herdr-child-watcher.sh arming publish, test-hold loop, post-sliced-wait refresh, and periodic refresh; herdr-child-supervision.sh reap-recovery refreshes in watcher_invalidation_action); none were left unguarded, because each writes its own generation onto a pane it may no longer own. A superseded refresh returns 20 and reaches the pre-existing watcher_fail path, whose publish_status -eq 20 branch removes the run and exits 0, retiring the stale watcher silently rather than publishing a spurious failure. A new HERDR_CHILD_TEST_LIVENESS_PUBLISH_BARRIER, bounded by the existing watcher_hold_expired, parks the watcher between its generation check and the publication. Verified on macOS by scripts_test.sh test 0421, which parks a real watcher at that barrier, runs a real herdr-child reply takeover to completion, releases the barrier, then asserts the stub herdr's calls.log carries no supervised=<old-generation> after the agent wait line, with positive controls that supervised=<new-generation> did reach the boundary and the new watcher is alive. Reverting the body to unconditional metadata_report turns it red at the stale-label assertion; restored it passes with 6 assertions. Collateral: tests/bashunit/herdr_child_descriptor_probe_test.sh stubbed a fixed supervision_generation of 1 while the real launcher publishes a 32-hex nonce, so the new precondition correctly rejected its publish and the test stopped reaching its blocked-liveness boundary; the stub now echoes back the generation it was told, as a real pane does. No assertion was weakened. make lint, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh (340 passed, 1 pre-existing skip, 341 total), herdr_child_descriptor_probe_test.sh (1 passed), make test-issues (58 tests OK), and make test-local (exit 0, content-only) all pass.
