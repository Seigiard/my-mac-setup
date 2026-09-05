---
title: "Bound transient herdr-child pane-read retries"
short_description: "Main polling and delivery-time revalidation retry non-pane_not_found pane get failures without a budget, so persistent Herdr transport or permission failures can leave supervision alive indefinitely without delivering a lifecycle event."
type: "bug"
category: "herdr"
tags: ["herdr-child","watcher","reliability"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-09-05"
---

## Why this exists

The main supervision loop retries every `herdr pane get` failure except
`pane_not_found` after a fixed poll delay. Persistent transport, permission,
or malformed error responses are therefore indistinguishable from a short
outage and can keep a watcher alive indefinitely while its run directory
remains present.

Delivery-time pane identity revalidation has the same failure class. Its
transient status returns to the watcher loop without consuming the existing
parent-delivery retry budget, so both pane-read sites need an explicit outage
policy.

## Scope

- Classify retryable pane-read failures separately from permanent failures.
- Bound or back off repeated transient failures while preserving recovery from
  short herdr outages.
- Publish a diagnostic supervision failure when the retry policy is exhausted.
- Add controls for one transient recovery and one persistent-failure outcome.

## Open decisions

- Whether this path should share the delivery retry budget or use a separate
  pane-read outage budget.

## Resolution

Both pane-read sites in home/dot_local/lib/herdr-child-watcher.sh now consume one shared budget bounded by the existing MAX_DELIVERY_RETRIES: the main poll loop's non-pane_not_found failure, and delivery-time identity revalidation status 12, which previously fell outside the 10|11 branch and retried with no accounting. Exhausting the budget routes through the existing watcher_fail terminal path. The open decision is resolved as sharing the delivery budget; no second budget was added. A pane_read_retry_pending guard keeps a poll read that succeeds between two failing delivery-time reads from refunding the budget every iteration, so a delivery-confined outage still terminates; the budget is refunded after a whole iteration whose pane reads all succeeded, and on a successful delivery. Known limitation: under a total transport outage no diagnostic can be published at all, because watcher_publish_failed gates on watcher_generation_current which itself performs a herdr pane get; the terminal state there is the watcher's exit plus failed.state. A bounded outage does publish, and the test observes that. Verified on macOS by scripts_test.sh test 0591, which drives a real herdr transport error for N pane reads and covers transient recovery (event still delivered, no failure published), budget exhaustion (wait-error published through the metadata boundary), and a permanent outage (real watcher process exit within a 20s bound). Deleting both budget checks turns it red at the wait-error assertion; restored it passes with 8 assertions. make lint, tests/lib/bashunit -j 8 tests/bashunit/scripts_test.sh (339 passed, 1 pre-existing skip, 340 total), make test-issues (58 tests OK), and make test-local (exit 0, content-only changes to .local/lib scripts) all pass.
