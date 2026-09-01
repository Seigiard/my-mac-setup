---
title: "Exercise Pi extensions through their registered consumer boundaries"
short_description: "Pi extension tests currently prove selection metadata, injected failure states, and handler registration while allowing prompt injection, package snapshots, subprocess timeouts, or the manual updater command to break without changing verdict."
type: "follow-up"
category: "agent-platform"
tags: ["pi","semantic-testing","behavioral-coverage"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The repository-wide test audit found four correlated false-green paths. tests/pi-agents-local-extension.test.ts never asserts the systemPrompt returned by before_agent_start. tests/pi-brew-auto-update.test.ts changes only package-lock.json while claiming package.json snapshot coverage, injects killed=true without observing options.timeout, and checks only that the manual command handler exists. Each suite can remain green while the behavior consumed by Pi users is broken.

## Scope

Strengthen the existing tests rather than adding duplicate suites. Invoke before_agent_start with distinct AGENTS.local.md and CLAUDE.local.md sentinels and assert the returned prompt preserves the base prompt, includes the selected file, and excludes the fallback. Give captureExtensionSnapshot separate package.json-only, lock-file-only, and unrelated-file controls. Capture ExecOptions and require every updater subprocess to receive the independently injected timeout. Invoke the registered brew-auto-update-now handler and observe the update sequence through the fake executor. Keep failure-notification behavior under 2026-08-21-022.

## Open decisions

Whether private diagnostic status strings remain a supported testing interface after the registered-hook coverage exists. Remove exact diagnostic inventories unless a real consumer depends on that vocabulary.
