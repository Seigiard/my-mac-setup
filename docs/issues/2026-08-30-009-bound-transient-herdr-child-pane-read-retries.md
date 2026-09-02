---
title: "Bound transient herdr-child pane-read retries"
short_description: "Main polling and delivery-time revalidation retry non-pane_not_found pane get failures without a budget, so persistent Herdr transport or permission failures can leave supervision alive indefinitely without delivering a lifecycle event."
type: "bug"
category: "herdr"
tags: ["herdr-child","watcher","reliability"]
date: "2026-08-30"
status: "open"
priority: "medium"
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
