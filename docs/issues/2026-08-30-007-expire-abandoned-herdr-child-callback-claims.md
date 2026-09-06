---
title: "Expire abandoned herdr-child callback claims"
short_description: "A callback.state value of status=in-progress makes the watcher poll forever when the callback owner dies before publishing confirmed or failed, leaving supervision unable to deliver or recover."
type: "bug"
category: "herdr"
tags: ["herdr-child","callback","reliability"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-09-05"
---

## Why this exists

When a blocked child starts callback delivery, `persist_callback_state` writes
`status=in-progress`. The watcher treats that value as authoritative and keeps
polling without checking whether the callback process still owns the claim.
If that process is killed before publishing `confirmed` or `failed`, the
generation can neither deliver its blocked event nor recover on its own.

## Scope

- Record enough callback-owner identity to distinguish a live claim from an
  abandoned or PID-reused claim.
- Let the watcher reclaim or fail an abandoned claim without duplicating a
  callback that is still live.
- Add a race test that kills the callback owner after `in-progress` publication
  and proves one bounded recovery outcome.

## Open decisions

- Whether an abandoned callback should retry parent delivery or publish a
  terminal supervision failure for an explicit managed retry.

## Resolution

An in-progress callback claim now records its owner's PID paired with the kernel start timestamp from ps -p <pid> -o lstart= (new process_start_marker in home/dot_local/lib/herdr-process.sh, matching the PID+start-time liveness pairing begin_supervision_transition already used). persist_callback_state fails closed when it cannot capture a marker, so no unexpirable claim is ever written. The watcher's blocked + in-progress poll branch checks callback_owner_alive and, on a dead owner, takes the existing terminal path watcher_fail ... callback-owner-lost with preserve_waiting=1, so the blocked=waiting for parent label survives and reap keeps refusing the pane. The open decision is resolved as a terminal supervision failure; no retry-delivery path was added. Verified on macOS by scripts_test.sh test 059, which SIGKILLs the real ask owner and requires the real watcher process to exit within a 20s bound against a 600s supervision timeout: with the liveness check mutated out the test exhausts the bound and fails at 29.5s, with it the test passes in 1.7s. make lint, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh (338 passed, 1 pre-existing platform skip), make test-issues (58 tests OK), and make test-local (exit 0, four .local/lib scripts mapped to their expected destinations) all pass.
