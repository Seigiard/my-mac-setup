---
title: Replace the deleted herdr-pair pattern reference
type: follow-up
date: 2026-08-18
status: open
---

## Why this exists

`docs/plans/2026-08-18-1254-fix-command-palette-defects-plan.md` points to `home/private_dot_claude/skills/herdr-pair/scripts/spawn-partner.sh:37` as the repository's hard-dependency error pattern. The child agent launch contract deletes the complete `herdr-pair` skill, so that implementation plan now points to a path available only in Git history.

`docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md` also names the removed read-only `ask-agent` invocation path. The replacement `ask-in-herdr` skill is live-agent-only and keeps an unscoped callback shell, so the old statement is no longer a valid implementation instruction.

The child launch work does not edit planning documents during execution. This issue keeps both stale references visible without mutating either planning artifact as execution progress.

## Scope

Before executing the command-palette defects plan, replace its deleted pattern reference with a surviving script that checks a required binary, writes a concrete error to stderr, and exits non-zero. Preserve the command-palette plan's required message content for `fzf`.

Before executing the dynamic-flow composition plan, replace its `ask-agent` requirement with the current Smithers external-agent contract. Do not route a headless Smithers leg through the herdr-only consult.

## Open decisions

- Which surviving script is the clearest hard-dependency pattern at implementation time.
- Whether the command-palette plan should name a commit and historical path when Git history remains the best example.
