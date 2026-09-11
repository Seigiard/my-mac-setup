---
title: "Share process hygiene across Detached workers"
short_description: "Adopt one descriptor-closure and process-identity implementation across Herdr Detached workers when a worker path next changes."
type: "follow-up"
category: "herdr"
tags: ["architecture","detached-worker","process-hygiene","enhancement","ready-for-agent"]
date: "2026-09-11"
status: "open"
priority: "low"
---

## Why this exists

Descriptor closure is copied three times and process-start identity has divergent locale and validation behavior, while the existing shared process module serves only the Child-agent contract.

## Scope

When a Detached worker path next changes, deepen herdr-process.sh to own descriptor closure and stable PID-plus-start identity for child lifecycle, worktree identity, and pane labels; leave claims, waits, recovery, and abandonment in each caller.

## Open decisions

Deferred until a worker path next changes; verify persisted process-start compatibility before consolidating implementations.
