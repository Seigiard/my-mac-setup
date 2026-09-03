---
title: "herdr-worktree-identity records contention for retry"
short_description: "The retired herdr-task-sync engine silently abandoned a contended claim after roughly 200 ms; herdr-worktree-identity now records contended as a non-terminal outcome so the next naming event retries without extending the fail-open bound."
type: "bug"
category: "herdr"
tags: ["worktree-identity","observability","contention"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-03"
---

## Why this exists

The retired `herdr-task-sync` engine could silently skip naming a generated
worktree on a loaded machine. Its 20-attempt claim bound, with a 10 ms sleep
between attempts, gave up after roughly 200 ms; callers then returned zero
without a diagnostic or identity state. The bound was reachable during normal
session contention, not only artificial load.

Raising the bound was not a remedy: a 2000-attempt experiment could exceed the
fail-open promptness guard. That measurement remains historical evidence for
the replacement design rather than behavior of the shipped component.

## Scope

`herdr-worktree-identity` keeps the short claim bound and implements KTD3: an
exhausted live-owner claim writes a `contended` diagnostic and leaves no
terminal identity outcome. The next session naming event retries the work;
neither a larger retry ceiling nor a second long-lived retry daemon is used.

The filename retains the retired component name as the historical record of the
reported defect.

## Open decisions

None. KTD3 settled the remedy before U5 implemented it.

## Resolution

U5 landed the KTD3 remedy in 2fe04a1: herdr-worktree-identity retains the short claim bound, records exhausted live-owner claims as contended diagnostics, and leaves the identity outcome non-terminal so the next naming event retries. This preserves fail-open promptness without a second retry daemon.
