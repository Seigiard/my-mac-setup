---
title: "plugin-doctor command exists only on the host, not reproducible from the repo"
short_description: "plugin-doctor command exists only on the host, not reproducible from the repo"
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "wontfix"
priority: "low"
closed: "2026-08-21"
---

## Why this exists

Commit `d4e32f9` removed `home/private_dot_claude/commands/plugin-doctor.md` with the message that the command is "now provided by plugins". That claim is not backed by the tracked config: `home/private_dot_claude/private_settings.json.tmpl` lists 8 enabled plugins and none of them provides plugin-doctor.

The capability still works on this machine only because an untracked copy survives at `~/.claude/commands/plugin-doctor.md`, outside chezmoi management. A clean machine rebuild (`chezmoi apply` from this repo) loses the command silently.

Found during the 2026-08-21 audit of `docs/plans/` (plan `docs/plans/2026-03-08-plugin-doctor-design.md`, now `status: superseded`).

## Scope

Pick one and make the repo state match it:

- Re-add the command file under `home/private_dot_claude/commands/` via `chezmoi add`, or
- Enable a marketplace plugin that actually provides plugin-doctor in `home/private_dot_claude/private_settings.json.tmpl`, or
- Decide the capability is not wanted and delete `~/.claude/commands/plugin-doctor.md` on the host.

Add a smoke test for whichever source is chosen.

## Open decisions

- Which of the three options above; depends on whether a marketplace plugin-doctor provider exists and is trusted.

## Resolution

Closed as wontfix: the user confirmed the plugin-doctor capability is deliberately abandoned — option 3. The untracked host copy at `~/.claude/commands/plugin-doctor.md` was already deleted when resolution started (the directory holds only `checkpoint.md`, `end-day.md`, `start-day.md`), so no host cleanup remains; the repo state and the host now agree that the command does not exist.

The other two options were ruled out on evidence, not skipped:

- Option 2 (plugin provider) has no provider: none of the 8 enabled plugins in `home/private_dot_claude/private_settings.json.tmpl` (claude-md-management, compound-engineering, frontend-design, playground, playwright, plugin-dev, security-guidance, typescript-lsp) ships a plugin-doctor command, and `~/.claude/plugins/cache` contains none. Commit `d4e32f9`'s deletion message ("now provided by plugins") was factually wrong — but the deletion outcome is now the wanted one.
- Option 1 (restore the tracked file) was built and offered as PR #30, and the user closed it unmerged as the explicit record of the not-taken alternative.

If the capability is ever wanted again, the full command file remains recoverable verbatim from git history: `git show d4e32f9^:home/private_dot_claude/commands/plugin-doctor.md`.
