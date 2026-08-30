---
title: "Expire abandoned herdr-child callback claims"
short_description: "A callback.state value of status=in-progress makes the watcher poll forever when the callback owner dies before publishing confirmed or failed, leaving supervision unable to deliver or recover."
type: "bug"
category: "herdr"
tags: ["herdr-child","callback","reliability"]
date: "2026-08-30"
status: "open"
priority: "medium"
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
