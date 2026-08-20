---
title: Deferred se-simplify findings for herdr-task-sync (quadratic scans and micro-refactors)
type: chore
date: 2026-08-20
status: open
parent-plan: docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md
---

## Why this exists

The se-simplify run over the label-system change produced 15 findings. The
applied ones (extracting `compose_tab_intents`, `repo_qualified_prefix`, the
single-jq final-token read, `deterministic_digest` via `table_value_for`,
`hts_upsert`, the two-pane bats fixture helper) landed with the merge that is
now on main. The rest were deferred on risk/benefit: each rewrite touches a
battle-tested label pipeline for a win that is invisible at the actual scale
(panes per sweep < ~20, worktree roots < ~10, sweep interval 5 s).

The run's own report lived under `/tmp/ce-simplify/run-1787217852465/` and is
ephemeral, so the deferred substance is recorded here. All line numbers are
against `home/dot_local/bin/executable_herdr-task-sync` on main at the time of
filing; each was re-verified to still exist in the merged code.

Deferred findings:

1. **Per-tab full rescan of `pane_presentations`** — `compose_tab_intents`
   re-reads the whole table (nested `while read` at line 1172) once per tab to
   pull that tab's rows: O(tabs × panes). A sort by the `pane_tab` field plus a
   single grouped pass would make it one linear walk.
2. **Stale-state cleanup rescan** — the `location.state` sweep (lines
   1529-1540) walks all of `pane_presentations` per state file to answer a
   membership question: O(state-files × panes). The merge introduced
   `list_contains_line` (line 905); extracting the pane-id column once and
   using it here is now a three-line change.
3. **`build_worktree_tokens` quadratic scans** — basename-collision counting
   (lines 843-848) and suffix-uniqueness probing (lines 854-868) both re-walk
   the full roots list per root: O(roots²) and O(roots² × path components).
   Precomputed `sort | uniq -c` tables would make both near-linear.
4. **`build_worktree_tokens` structure** — the function mixes basename
   selection, shortest-unique-suffix search, digest fallback, and ordinal
   fallback in one body, and reuses the variable `count` for two meanings
   (basename matches at line 843, suffix component count at line 854). Split
   into helpers, or at minimum rename the two counters.
5. **First-value/divergence idiom duplicated** — `first_repo`/`multiple_repos`
   (lines 1180-1186) and `first_root`/`multiple_roots` (lines 1188-1196)
   implement the same "remember first value, flag a later distinct value"
   bookkeeping side by side inside `compose_tab_intents`.
6. **Inline tab-segment prefix rule** — the compact tab prefix (lines
   1512-1519) restates `git_ref_for` inputs with only ref truncation and
   folder suppression changed; a `git_ref_segment_for` helper would name the
   rule once.

## Scope

- None of these changes behavior; every one must keep labels byte-identical
  under the existing bats suite (`bats tests/scripts.bats`).
- Items 2 and 5 are small and safe to take opportunistically with the next
  change that touches their code.
- Items 1, 3, 4, and 6 are batch work: only worth doing together, and only if
  the sweep ever gets slow enough to matter or the code is being reworked
  anyway (for example by the record restructuring in
  `docs/issues/2026-08-20-008-field-separator-positional-record-bus.md`).

## Open decisions

- Whether items 1 and 3 are worth doing at all at the current scale. Measure a
  sweep with a realistic pane count before optimizing; close as wontfix if the
  pass stays well inside the 5-second interval.
