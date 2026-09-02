---
title: "herdr-task-sync gives up on worktree identity after a 200 ms claim bound, silently"
short_description: "acquire_claim retries INBOX_LOCK_ATTEMPTS=20 times at 10 ms, so a contended claim is abandoned after ~200 ms, and every caller in apply_worktree_identity converts that into a bare return 0 that leaves no trace."
type: "bug"
category: "herdr"
tags: ["herdr-task-sync","worktree-identity","observability"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

On a loaded machine herdr-task-sync can silently skip naming a generated worktree. home/dot_local/bin/executable_herdr-task-sync:130 sets INBOX_LOCK_ATTEMPTS=20 and acquire_claim (:354) sleeps 0.01 between attempts, so acquiring a claim is abandoned after roughly 200 ms of wall clock. A single agent session drives several engine processes -- the event, the naming worker, the presentation coordinator -- that contend for the same identity and repository claims, so the bound is reachable in normal use, not only under artificial load. Every caller then turns the failure into a silent return 0 (:1922, :2316, :2364, :2485), so the branch is not renamed, no record is written, and nothing is logged. This was measured on the GitHub macOS runner: with the shipped bound the full scripts suite at --jobs 8 failed six worktree-identity tests on every run, and raising only HERDR_TASK_SYNC_LOCK_ATTEMPTS made all six pass. The test harness now raises the ceiling for its own runs, which fixes CI but leaves the shipped bound and the silent failure untouched.

## Scope

Decide and implement a production-appropriate claim bound for the herdr-task-sync engine, and make an exhausted claim observable rather than silent. Covers home/dot_local/bin/executable_herdr-task-sync only; the test harness default in tests/helpers/herdr_task_sync.bash is already handled.

## Open decisions

Whether the fix is a larger attempt count, an escalating backoff, or a wall-clock deadline separate from the attempt count. Whether an exhausted claim should emit a diagnostic line and, if so, on which channel given the engine must stay silent outside herdr. Whether apply_worktree_identity should distinguish give-up from not-applicable, since return 0 currently means both.
