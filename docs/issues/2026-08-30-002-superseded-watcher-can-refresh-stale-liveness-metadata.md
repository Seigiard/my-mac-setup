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

Describe the problem and its impact.

## Scope

Define the work that resolves this issue.

## Open decisions

None.
