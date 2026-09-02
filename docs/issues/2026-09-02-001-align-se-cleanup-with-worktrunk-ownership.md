---
title: "Retire se-cleanup in favor of Worktrunk"
short_description: "Worktrunk's command-palette remover now owns safe worktree deletion and Herdr workspace closure, so the obsolete agent skill and its deployment adapters should remain absent."
type: "bug"
category: "agent-platform"
tags: ["se-cleanup","worktrunk","herdr"]
date: "2026-09-02"
status: "done"
priority: "high"
closed: "2026-09-02"
---

## Why this exists

`se-cleanup` predates the Worktrunk migration and still runs `git worktree
remove`, `git branch -d`, and `git push origin --delete` itself. This conflicts
with `docs/worktrunk-workspaces.md`, which makes Worktrunk the single owner of
interactive worktree removal in Herdr.

Three 2026-09-01 invocations show the resulting drift:

- OpenCode session `ses_fa3500c2effeZBvJ4DHUVmb14r` and Claude sessions
  `75778e84-61dc-4fb4-9995-5805dda168d7` and
  `1885f1d3-21b1-4a93-99ba-f6bde4d7f4d7` all tried to delete remote branches
  that GitHub had already auto-deleted. The command failed even though the
  desired remote state was already true.
- Both Claude sessions removed their own current checkout directly. Every
  later Bash call then emitted a non-blocking hook error because
  `${CLAUDE_PROJECT_DIR}/.claude/hooks/command-bans.ts` was inside the removed
  worktree.
- The agents piped commands through `tail` and printed empty or misleading
  status values, including `EXIT=0` after a failed remote deletion. The skill's
  multi-command manual workflow encourages status-handling drift.
- Direct Git removal bypassed the `herdr-worktrunk` remover's workspace and pane
  cleanup. Worktrunk itself can safely classify squash-merged branches and
  return structured removal outcomes, but the skill does not use it.

The installed `herdr-worktrunk` plugin closes matching Herdr workspaces after
`wt remove --foreground`, but its `worktrunk.remove` action currently opens an
interactive picker. It has no targetable non-interactive action for an agent
running inside the worktree being removed.

## Scope

Remove `se-cleanup` from the repository-owned skill tree, Claude adapter,
inventory, and deployment manifest. Keep Worktrunk's command-palette remover as
the single owner of worktree safety checks, branch removal, and Herdr workspace
closure. Extend the existing retired-skill deployment check so a later change
cannot silently restore the canonical skill or a client adapter.

## Open decisions

None. The user selected manual `wtd` removal over maintaining a second cleanup
workflow.

## Resolution

Removed the canonical se-cleanup skill and Claude adapter, removed it from repository inventories and deployment expectations, and added it to the deployed retired-skill absence check. Worktrunk's wtd command-palette flow is now the sole cleanup workflow.
