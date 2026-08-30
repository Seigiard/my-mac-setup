---
title: "herdr-child watcher event delivery erases a pending reap run before pane close"
short_description: "When a supervision event (e.g. timeout) is being delivered in the same watcher iteration that a reap invalidation lands, deliver_supervision_event returns 20 on invalidated.state regardless of reason=reap, so the watcher removes the run dir and exits instead of deferring to watcher_invalidation_action; a reap that then fails pane close cannot signal reap-restore (the run dir is gone) and falls to the degraded publish_reap_recovery path, and the invalidation evidence disappears before close."
type: "bug"
category: "herdr"
tags: ["herdr","race"]
date: "2026-08-30"
status: "open"
priority: "low"
---

## Why this exists

Found while fixing the 2026-08-29-004 test flake: the loaded-scheduler interleaving (deadline expiring mid-reap) was reproduced deterministically 6/6 and traced to deliver_supervision_event's unconditional invalidated.state -> return 20 -> remove_supervision_run shortcut in home/dot_local/bin/executable_herdr-child. The parent-wake contract still holds (no spurious child-gone), but the reap-restore recovery path silently degrades in this window, and tests 046/047 still start supervision with a 5000ms deadline that could expire mid-scenario under extreme load. A parallel branch is reworking watcher lifecycle in the same file; coordinate before changing teardown logic.

## Scope

Decide whether deliver_supervision_event should treat invalidated.state with reason=reap plus a live reap-pending owner as a defer (let watcher_invalidation_action wait for reap-closed/reap-restore) instead of returning 20. Cover with a semantic regression test that forces the delivery-window interleaving. Consider widening the 5000ms supervision timeouts in tests 046/047 the same way 045 was widened.

## Open decisions

None.
