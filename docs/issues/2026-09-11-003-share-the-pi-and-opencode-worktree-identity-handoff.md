---
title: "Share the Pi and OpenCode worktree-identity handoff"
short_description: "Consolidate duplicated engine discovery, stdin transport, timeout, and fail-open settlement when either TypeScript adapter next changes."
type: "follow-up"
category: "agent-platform"
tags: ["architecture","worktree-identity","adapter","enhancement","ready-for-agent"]
date: "2026-09-11"
status: "open"
priority: "low"
---

## Why this exists

Pi and OpenCode independently implement the same one-second subprocess handoff, creating a real two-adapter seam where transport behavior can drift.

## Scope

When either adapter next requires modification, move only the shared TypeScript engine handoff behind one internal interface; keep client event normalization local and keep the Claude shell adapter separate.

## Open decisions

Deferred until one adapter next changes; revalidate that both implementations still match before extracting the shared handoff.
