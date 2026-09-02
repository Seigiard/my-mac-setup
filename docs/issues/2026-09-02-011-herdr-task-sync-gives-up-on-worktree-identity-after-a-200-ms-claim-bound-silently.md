---
title: "herdr-task-sync gives up on worktree identity after a 200 ms claim bound, silently"
short_description: "acquire_claim retries INBOX_LOCK_ATTEMPTS=20 times at 10 ms, so a contended claim is abandoned after ~200 ms and every caller in apply_worktree_identity converts that into a bare return 0 that leaves no trace; simply raising the count breaks the engine fail-open promptness guarantee instead."
type: "bug"
category: "herdr"
tags: ["herdr-task-sync","worktree-identity","observability"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

On a loaded machine herdr-task-sync can silently skip naming a generated worktree. home/dot_local/bin/executable_herdr-task-sync:130 sets INBOX_LOCK_ATTEMPTS=20 and acquire_claim (:354) sleeps 0.01 between attempts, so acquiring a claim is abandoned after roughly 200 ms of wall clock. A single agent session drives several engine processes -- the event, the naming worker, the presentation coordinator -- that contend for the same identity and repository claims, so the bound is reachable in normal use, not only under artificial load. Every caller then turns the failure into a silent return 0 (:1922, :2316, :2364, :2485), so the branch is not renamed, no record is written, and nothing is logged. This surfaced on the GitHub macOS runner (3 cores), where the post-apply suite ran 8 workers: the worktree-identity tests failed on every run because the claim bound lost to the scheduler. That CI symptom is fixed by matching the worker count to the runner instead, so the shipped bound and the silent failure are untouched and still reachable on a loaded developer machine.

Raising the bound is NOT the remedy, and the measurement says why. A harness ceiling of 2000 attempts (~20 s) was tried first: at 8 workers it fixed two of the six tests, broke a fail-open promptness test, and left five failing; at 4 workers it still failed one, with the engine reporting `elapsed_ms=8395 allowed_ms=8136` -- it spun in the retry loop for 8.4 s where the fail-open guard allows 8.1. So a claim ceiling large enough to survive contention violates the promptness guarantee the engine is separately required to keep. Any fix here has to reconcile those two obligations rather than trade one for the other.

## Scope

Decide and implement a production-appropriate claim bound for the herdr-task-sync engine, and make an exhausted claim observable rather than silent. Covers home/dot_local/bin/executable_herdr-task-sync only. The CI failure that exposed it is fixed separately by capping the macOS post-apply worker count, and the test harness carries no compensating override.

## Open decisions

Whether the fix is an escalating backoff, a wall-clock deadline separate from the attempt count, or a bound that yields to the caller instead of spinning -- a larger attempt count alone is ruled out by the measurement above. Whether an exhausted claim should emit a diagnostic line and, if so, on which channel given the engine must stay silent outside herdr. Whether apply_worktree_identity should distinguish give-up from not-applicable, since return 0 currently means both.
