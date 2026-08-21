---
title: "Automatically load local agent instructions into OpenCode and Pi system prompts"
short_description: "Use each client's native settings, hooks, or plugin API to discover applicable `CLAUDE.local.md` and `AGENTS.local.md` files and append ordered, deduplicated instructions before request processing."
type: "idea"
category: "agent-platform"
tags: ["local-instructions","system-prompt","opencode","pi"]
date: "2026-08-21"
status: "open"
priority: "medium"
---

## Why this exists

Shared agent instructions currently need conditional text that tells OpenCode and Pi to check for `CLAUDE.local.md` or `AGENTS.local.md`. This makes instruction files depend on agent compliance and duplicates behavior that belongs in the agent bootstrap layer.

OpenCode and Pi should discover applicable local instruction files before a turn starts and append their contents to the system prompt. Agents can then receive repository-specific or machine-specific guidance without explicit lookup conditions in shared instructions.

## Scope

- Investigate native settings, hooks, and plugin APIs in OpenCode and Pi for system-prompt augmentation.
- Implement automatic discovery of `CLAUDE.local.md` and `AGENTS.local.md` for the active working directory.
- Define directory traversal, precedence, ordering, and duplicate handling when more than one local file applies.
- Append discovered instructions to the system prompt before the agent processes the user request.
- Remove obsolete conditional lookup instructions after both clients load the files reliably.
- Add verification that covers OpenCode and Pi startup from directories with and without local instruction files.
- Document the selected configuration or plugin mechanism and its limitations.

## Open decisions

- Decide whether each client should load both file names or only its native local-instruction file.
- Decide whether discovery stops at the repository root or continues through parent directories.
- Decide whether missing or unreadable local files should be silent, logged, or treated as startup errors.
