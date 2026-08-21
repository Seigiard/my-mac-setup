---
title: plugin-doctor command exists only on the host, not reproducible from the repo
type: bug
date: 2026-08-21
status: open
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
