---
title: plugin-doctor command exists only on the host, not reproducible from the repo
type: bug
date: 2026-08-21
status: done
closed: 2026-08-21
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

Option 1 taken: the command file is restored under chezmoi management at `home/private_dot_claude/commands/plugin-doctor.md`, recovered verbatim (66 lines) from git history via `git show d4e32f9^:home/private_dot_claude/commands/plugin-doctor.md` — the parent commit of the deletion. A smoke test in `tests/smoke.bats` asserts the source file is tracked and the deployed `~/.claude/commands/plugin-doctor.md` exists after apply.

Evidence behind the choice:

- The deletion reason in `d4e32f9` ("now provided by plugins") is factually wrong: none of the 8 enabled plugins in `home/private_dot_claude/private_settings.json.tmpl` (claude-md-management, compound-engineering, frontend-design, playground, playwright, plugin-dev, security-guidance, typescript-lsp) provides a plugin-doctor command, and `~/.claude/plugins/cache` contains no such command either — so option 2 had no provider to enable.
- During resolution the untracked host copy at `~/.claude/commands/plugin-doctor.md` turned out to be already gone (the directory holds only `checkpoint.md`, `end-day.md`, `start-day.md`), so the capability was lost on this machine too, not just on a clean rebuild.
- If that host deletion was a deliberate abandonment of the capability (option 3), the restoring PR is the review gate: closing it unmerged records that choice.

Neither `home/.chezmoiignore` nor `home/.chezmoiexternal.toml` touches `.claude/commands`, so single-source management holds. The deployed copy returns only after the user runs `chezmoi apply`; until then the new smoke-test assertion on the deployed path is red on the host (green in Docker CI, which applies the checkout first). Commit: the commit that carries this Resolution.
