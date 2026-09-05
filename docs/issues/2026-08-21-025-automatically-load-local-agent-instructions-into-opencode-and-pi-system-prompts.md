---
title: "Automatically load local agent instructions into OpenCode and Pi system prompts"
short_description: "OpenCode and Pi both append the project's local instructions to the system prompt through one shared selection module (~/.local/lib/agent-hooks/local-instructions.ts); a single file wins per project (AGENTS.local.md over CLAUDE.local.md, cwd only), symlinks escaping the project root and files over 50 KiB are rejected, and OpenCode's append is guarded by the emitted heading so repeated transforms stay idempotent."
type: "idea"
category: "agent-platform"
tags: ["local-instructions","system-prompt","opencode","pi"]
date: "2026-08-21"
status: "done"
priority: "medium"
closed: "2026-09-05"
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

## Resolution

Both clients now load local instructions from one shared module. Pi's extension and a new OpenCode plugin (home/private_dot_config/opencode/plugins/agents-local.ts) import home/dot_local/lib/agent-hooks/local-instructions.ts, so symlink resolution, project-escape rejection, the 50 KiB cap and the emitted block exist once. OpenCode injects through experimental.chat.system.transform and appends only when the '## Local Private Project Instructions' heading is absent from the system array, which keeps the injection idempotent whether the hook receives a freshly built array or an accumulated one; a probe plugin driving a real OpenCode 1.18.20 session showed the array rebuilt per request. Pi's once-per-cwd ui.notify warning stays in the Pi extension; OpenCode has no equivalent channel and drops it.

Settled scope decisions: discovery covers the working directory only, not parent directories; exactly one file is selected per project (AGENTS.local.md preferred over CLAUDE.local.md) instead of merging both, so ordering and deduplication do not arise; missing files are silent in both clients, and unreadable or rejected files warn in Pi and are silent in OpenCode.

Native support was checked first, because it would have made the port unnecessary: OpenCode 1.18.20 reads neither file natively. Its binary contains the strings 'AGENTS.md' and 'CLAUDE.md' and no 'AGENTS.local.md' or 'CLAUDE.local.md', and a probe plugin dumping the system array from a real session in a project holding both files found the AGENTS.md sentinel present and the AGENTS.local.md sentinel absent.

Verified by tests/agents-local-opencode-plugin.test.ts (shared-module parity, escape and size-cap rejection with in-project controls, idempotence, no-op when no local file exists, and the absent import edge between local-instructions and the dispatch core), the unchanged assertions of tests/pi-agents-local-extension.test.ts, and deployed-path coverage in tests/bashunit/smoke_test.sh (cases 1055 and 1070).
