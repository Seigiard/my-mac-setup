---
title: "Add /se-cleanup post-merge skill"
short_description: "A guarded Bash script should finish merged PR work by returning to the remote default branch, removing the feature worktree, and deleting local and remote feature branches without touching dirty or open work."
type: "idea"
category: "agent-platform"
tags: ["skill","git","worktree","pull-request"]
date: "2026-08-22"
status: "open"
priority: "medium"
---

## Why this exists

Post-merge cleanup currently requires repeated manual Git and GitHub commands. The sequence is easy to perform in the wrong checkout, against an open PR, or before the default branch contains the merge.

## Scope

Add home/private_dot_claude/skills/se-cleanup/SKILL.md and a skill-owned Bash script. The script must resolve the repository and default branch, verify that the pull request is merged, refuse dirty worktrees, switch the primary checkout to the default branch, update it with fast-forward-only semantics, remove the completed secondary worktree when present, delete the merged local branch, delete its remote branch when safe, prune stale worktree metadata, and finish with a clean-state report. Add tests for primary-checkout, secondary-worktree, no-extra-worktree, dirty-tree, open-PR, missing-upstream, and non-fast-forward cases.

## Open decisions

Decide whether remote branch deletion is unconditional after a confirmed merge or configurable; define behavior when the command starts inside the worktree that it must remove; decide whether closed-but-unmerged PRs are eligible; and define recovery output when default-branch synchronization cannot fast-forward.
