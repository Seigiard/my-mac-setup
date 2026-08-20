---
title: Harden herdr-task-sync and show worktree identity
type: follow-up
date: 2026-08-18
status: open
---

## Why this exists

`home/dot_local/bin/executable_herdr-task-sync` owns prompt-aware agent names, pane labels, and composed tab labels. It does not expose the Git worktree in which an agent runs. This makes parallel agents with similar tasks difficult to distinguish.

The engine also starts one detached worker per prompt. Metadata reports use a monotonic sequence, but pane and tab renames do not. State files are written directly without a per-session lock. An older naming worker can therefore overwrite a newer pane label, tab label, or state file.

The comparison in `docs/ideation/2026-08-18-herdr-title-plugins-pov.html` found no complete replacement. It identified reusable patterns in `herdr-whereami`, `herdr-plugin-renamer`, `herdr-titles`, `herdr-tab-renamer`, and `herdr-automatic-rename`.

## Scope

- Derive `repo`, `worktree`, and `branch` from the pane's current working directory.
- Publish location values as source-owned pane metadata with stale-token cleanup.
- Show a concise worktree identity in the agents sidebar and once in each composed tab label.
- Keep one local owner for pane and tab labels. Do not install another whole-label writer beside `herdr-task-sync`.
- Serialize or coalesce overlapping naming workers per pane and session.
- Write state by atomic replacement and validate the current generation before pane and tab renames.
- Treat Herdr events as invalidation. Fetch current pane and tab state immediately before applying a rename.
- Preserve the periodic sweep as a fallback for foreground command changes that Herdr does not emit.
- Add concurrency, manual-ownership, mixed-worktree, and stale-token tests.

## Planning decisions

- The visible identity uses an 18-column worktree basename, shortest session-unique suffix, or collision-checked basename-plus-digest token; repository and branch remain separate metadata.
- Location metadata belongs in `herdr-task-sync`, which remains the only pane and tab label writer.
- Manual pane and tab ownership is independent and persists until separate explicit reclaim actions.
- Manual ownership becomes durable only after a fresh reconciliation observes divergence because Herdr 0.8 rename calls have no compare-and-swap or writer sequence.
- Agent adapters synchronously commit only the bounded enqueue generation, then detach model and presentation work.
- Retained location identity shows a plain-text `stale` state until fresh Git or confirmed non-Git evidence arrives.
- Rollout uses a versioned takeover so a pre-upgrade sweep daemon cannot remain a second label writer.
- Rollout also proves that no detached legacy naming worker remains before the upgraded coordinator becomes presentation-ready.
- Reclaim actions use durable request IDs and report an end-to-end result through Herdr notifications within five seconds.
- Icons, Nerd Font integration, and decorative formatters are outside scope.
- The implementation contract lives in `docs/plans/2026-08-18-001-feat-herdr-worktree-aware-labels-plan.md`.
