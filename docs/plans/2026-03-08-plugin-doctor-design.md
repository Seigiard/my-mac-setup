---
status: superseded
superseded-by: commit d4e32f9 — command dropped in favor of an external plugin (reproducibility gap filed separately)
---

# Plugin Doctor — Design

## Problem

Claude Code plugins can end up with corrupted cache — `installed_plugins.json` has an entry but the cache directory is missing `.claude-plugin/plugin.json`. The UI shows "Disabled" but attempting to enable says "already enabled". Manual fix requires editing JSON + clearing cache + reinstalling.

## Solution

A Claude Code slash command `/plugin-doctor` that automatically detects and repairs broken plugins.

## How It Works

1. Read `~/.claude/plugins/installed_plugins.json`
2. For each plugin entry, check if `installPath/.claude-plugin/plugin.json` exists
3. Classify broken plugins by scope:
   - **user scope** → auto-fix via `claude plugin uninstall -s user <name>` + `claude plugin install -s user <name>`
   - **project/local scope** → output warning with copy-paste commands (requires being in the correct project directory)
4. Report results

## Output Format

```
Plugin Doctor Report
────────────────────
OK       24 plugins healthy
FIXED     4 plugins reinstalled (user scope)
WARNING   2 plugins need manual fix (project scope):
  → cd /path/to/project && claude plugin uninstall -s project <name> && claude plugin install -s project <name>
```

## Location

- Source: `home/private_dot_claude/commands/plugin-doctor.md`
- Installed to: `~/.claude/commands/plugin-doctor.md`
- Invoked as: `/plugin-doctor`

## Decisions

- **Auto-fix for user scope** — no confirmation needed, fully automated
- **Warnings for project/local scope** — can't auto-fix without being in the right directory
- **Uses `claude plugin` CLI** — official tooling, not manual JSON editing
- **Slash command format** — consistent with existing commands (gc.md, start-day.md)
