---
title: "Exercise Pi extensions through their registered consumer boundaries"
short_description: "Pi extension tests currently prove selection metadata, injected failure states, and handler registration while allowing prompt injection, package snapshots, subprocess timeouts, or the manual updater command to break without changing verdict."
type: "follow-up"
category: "agent-platform"
tags: ["pi","semantic-testing","behavioral-coverage"]
date: "2026-09-01"
status: "done"
priority: "medium"
closed: "2026-09-02"
---

## Why this exists

The repository-wide test audit found four correlated false-green paths. tests/pi-agents-local-extension.test.ts never asserts the systemPrompt returned by before_agent_start. tests/pi-brew-auto-update.test.ts changes only package-lock.json while claiming package.json snapshot coverage, injects killed=true without observing options.timeout, and checks only that the manual command handler exists. Each suite can remain green while the behavior consumed by Pi users is broken.

## Scope

Strengthen the existing tests rather than adding duplicate suites. Invoke before_agent_start with distinct AGENTS.local.md and CLAUDE.local.md sentinels and assert the returned prompt preserves the base prompt, includes the selected file, and excludes the fallback. Give captureExtensionSnapshot separate package.json-only, lock-file-only, and unrelated-file controls. Capture ExecOptions and require every updater subprocess to receive the independently injected timeout. Invoke the registered brew-auto-update-now handler and observe the update sequence through the fake executor. Keep failure-notification behavior under 2026-08-21-022.

## Open decisions

Settled: private diagnostic status strings (`candidate`, `skipped-preferred-agents`, `skipped-broken-symlink`, `skipped-outside-project`, `skipped-too-large`, `skipped-not-file`, `skipped-unreadable`, etc.) are not a supported testing interface. A repo-wide search found no consumer of `LocalInstructionDiagnostic`/`selection.diagnostics` outside `home/dot_pi/agent/extensions/agents-local.ts` itself and its test file. The `selection.diagnostics.map(...).toEqual([...])` deep-equality inventories in `tests/pi-agents-local-extension.test.ts` were removed; the suite keeps assertions on which file was selected (`selection.selected?.name`) and on user-visible warning text (`selection.warnings`), now backed by direct `before_agent_start` prompt-content assertions using independent sentinels. If a real external consumer of the diagnostic-status vocabulary is added later, restore targeted status assertions at that boundary rather than reintroducing the full-array inventory.

## Resolution

Merged in PR #137. The returned systemPrompt is asserted against independent sentinels, extension-snapshot coverage is split into package.json-only, lock-file-only and unrelated-file controls, every updater subprocess is required to receive an injected timeout distinct from the production default, and the registered brew-auto-update-now handler is invoked through registerBrewAutoUpdater with its command sequence observed. Each closed path carries a mutation proof. Diagnostic-status inventories were removed after a repository search found no consumer of that vocabulary outside the extension and its own test.
