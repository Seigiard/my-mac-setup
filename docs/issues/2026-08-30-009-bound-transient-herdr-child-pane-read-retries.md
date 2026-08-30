---
title: "Bound transient herdr-child pane-read retries"
short_description: "The watcher treats every non-pane_not_found pane get failure as transient and retries forever, so persistent herdr transport or permission failures can leave a supervision watcher alive indefinitely."
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

## Scope

- Classify retryable pane-read failures separately from permanent failures.
- Bound or back off repeated transient failures while preserving recovery from
  short herdr outages.
- Publish a diagnostic supervision failure when the retry policy is exhausted.
- Add controls for one transient recovery and one persistent-failure outcome.

## Open decisions

- Whether this path should share the delivery retry budget or use a separate
  pane-read outage budget.
