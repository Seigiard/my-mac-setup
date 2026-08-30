---
title: "Superseded watcher can refresh stale liveness metadata"
short_description: "refresh_supervision_liveness publishes supervised=<old-generation> without an under-lock generation precondition, so a watcher already in the refresh path can update stale liveness after a managed takeover."
type: "bug"
category: "herdr"
tags: ["concurrency"]
date: "2026-08-30"
status: "open"
priority: "medium"
---

## Why this exists

`watch_child` checks `watcher_generation_current` after a sliced `herdr agent wait`, then calls `refresh_supervision_liveness` separately. The refresh uses unconditional `metadata_report`, unlike failure publication's generation-checked `metadata_report_if_generation`. A managed continuation can publish its new generation after the watcher check but before the refresh acquires the pane metadata lock, allowing the old watcher to publish a newer `supervised=<old-generation>` label over the active generation.

The neighboring sliced-wait regression only changes the generation before `watcher_generation_current`; it does not place takeover between that check and publication. Metadata sequence serialization therefore does not close this race because the stale refresh can legitimately receive the later sequence.

## Scope

Publish liveness through `metadata_report_if_generation` so generation, terminal, and session identity are revalidated while holding the per-pane metadata lock. Add a barrier-driven semantic regression that pauses the old watcher after its ordinary generation check, completes a managed takeover, then proves the old generation cannot publish liveness.

## Open decisions

None.
