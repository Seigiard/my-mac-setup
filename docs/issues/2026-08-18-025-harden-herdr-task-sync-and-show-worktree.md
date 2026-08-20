---
title: Harden herdr-task-sync and show worktree identity
type: follow-up
date: 2026-08-18
status: done
closed: 2026-08-20
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

## Resolution

Closed by audit on 2026-08-20: every scope bullet shipped on main through the
worktree-aware-labels work (`docs/plans/2026-08-18-001-feat-herdr-worktree-aware-labels-plan.md`)
and the label-system merge that followed it
(`docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md`, commits
`f7fd73c`..`9e69d0b`). No code change was needed here. All pointers are into
`home/dot_local/bin/executable_herdr-task-sync` unless stated.

Scope bullets, one by one:

- **Derive `repo`, `worktree`, `branch` from the pane cwd** — done.
  `resolve_pane_location` (line 672) resolves checkout root, common git dir,
  repo, symbolic branch, linked-worktree flag, and detached short SHA from the
  pane's `cwd`/`foreground_cwd`, under a 75 ms per-pane Git budget.
- **Source-owned location metadata with stale-token cleanup** — done.
  Location tokens publish via `herdr pane report-metadata --source
  location-sync` (lines 1615-1626); leaving Git clears `repo`, `worktree`,
  `branch`, `location_status`, `git_ref`; every write path also clears the
  retired `location_label` token. Tests: `tests/scripts.bats` "clears the
  retired location_label token on both publish and non-git clear paths" and
  "clears a retired location_label even when every published token already
  matches".
- **Concise worktree identity in sidebar and once per tab** — done.
  `build_worktree_tokens` (line 836) implements exactly the planned budget:
  18-column basename, shortest session-unique path suffix, collision-checked
  basename-plus-digest, ordinal fallback. The `$git_ref` token renders it in
  the two-row sidebar (`home/private_dot_config/herdr/config.toml:57`), and
  `compose_tab_intents` (line 1142) hoists a shared ref once per tab.
- **One local label owner** — done. `herdr-task-sync` is the only pane/tab
  label writer; the herdr plugin only requests reconciliation, and a
  reconciliation pass converges externally renamed labels back to computed
  intent (test "presentation automatically corrects divergent pane and tab
  labels").
- **Serialize/coalesce overlapping naming workers** — done. Per-pane
  `control.lock` inbox + `worker.claim` single worker with monotonic
  generations (`run_worker`, line 1974; `commit_task_result`, line 1875);
  only the latest committed generation for the active session publishes
  (tests "latest committed request survives stale completion and a third
  request", "orders adapter calls by inbox commit rather than invocation
  start").
- **Atomic state writes + generation validation before renames** — done.
  All records go through `atomic_write` (mktemp + mv, line 190);
  `presentation_generation_valid` (line 1033) gates every metadata write and
  rename (tests "atomic records never expose truncation or mixed fields",
  "presentation publishes only the newest accepted generation", "presentation
  resumes safely across durable crash boundaries").
- **Events as invalidation; re-read targets before rename** — done. `--event`
  bumps the pending generation and each pass takes a fresh snapshot, then
  `herdr pane get`/`herdr tab get` immediately before each mutation with full
  target-identity matching (tests "presentation coalesces event bursts…",
  "presentation skips reused pane and tab identities at the final read").
- **Periodic sweep as fallback** — done. `run_sweep_daemon` (line 1717) keeps
  the 5 s sweep for foreground changes herdr does not emit (tests "sweep
  repairs an external pane rename without pane.updated", "sweep repairs
  process and CWD changes through the presentation coordinator").
- **Concurrency, manual-ownership, mixed-worktree, stale-token tests** — done.
  Concurrency: shared-tab concurrent panes, event bursts, colliding sockets,
  eight-pane concurrent location resolution. Manual ownership: covered under
  the superseded design (see below) as "divergence is repaired, no ownership
  state" — the forbidden-state test greps for
  `manual_owner|reclaim|label_ledger|server_epoch|takeover`. Mixed-worktree:
  token suffix/digest/ordinal tests plus the mixed-identity formatter tests.
  Stale-token: transient-retention, detached-SHA-failure, and both
  location_label-clearing tests.

Superseded, not skipped: the manual-ownership durability, reclaim request IDs
+ notifications, and versioned-takeover rollout machinery listed under
Planning decisions were explicitly dropped during plan deepening —
`docs/plans/2026-08-18-001-feat-herdr-worktree-aware-labels-plan.md` scopes
this issue "except for its superseded manual-label and reclaim scope", and its
R7-R9 replace them: labels are fully automatic, divergent live labels are
converged back, restarts recompute rather than adopt, and no ownership or
takeover state exists (enforced by test).

Residual gaps found by the audit are already filed separately and stay open on
their own: `docs/issues/2026-08-20-005` (pane_inline published but unused),
`2026-08-20-007` (label-system test gaps), `2026-08-20-008` (positional record
bus), `2026-08-20-010` (two tests flake under full-suite load), `2026-08-20-011`
(deferred simplify findings), `2026-08-20-012` (same-name repos defeat tab
repo qualification).
