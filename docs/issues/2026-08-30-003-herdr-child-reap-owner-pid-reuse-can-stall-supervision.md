---
title: "herdr-child reap owner PID reuse can stall supervision"
short_description: "watcher_invalidation_action identifies a pending reap only with kill -0 on owner_pid, so PID reuse can make an unrelated process hold supervision in the reap-recovery loop indefinitely."
type: "follow-up"
category: "herdr"
tags: ["herdr","race"]
date: "2026-08-30"
status: "open"
priority: "low"
---

## Why this exists

Review of reap recovery found that `reap-pending.state` records only `owner_pid`, and `watcher_invalidation_action` treats `kill -0` as ownership proof. If reap dies and the operating system reuses that PID for an unrelated long-lived process before the watcher observes the death, no `reap-closed` or `reap-restore` transition will arrive. The watcher can remain in the recovery loop indefinitely and stop delivering later child events.

## Scope

Give a reap attempt an identity stronger than PID existence, such as a nonce plus bounded lease or a process-start identity available on both macOS and Linux. Make stale-owner recovery deterministic without converting a slow but live pane close into premature restoration. Add a deterministic test fixture that substitutes an unrelated live process for the recorded owner.

## Open decisions

- Which owner identity is portable across macOS and Linux without adding a heavyweight dependency?
- What bound distinguishes a stale owner from a legitimately slow pane close under load?
