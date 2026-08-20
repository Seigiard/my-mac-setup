---
title: Deferred se-simplify findings for herdr-task-sync (quadratic scans and micro-refactors)
type: chore
date: 2026-08-20
status: done
closed: 2026-08-20
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

## Resolution

Commit ad2f181. Labels stayed byte-identical:
`tests/scripts.bats` 188/189 and `tests/smoke.bats` 106/107, `make lint`
clean. The two reds are pre-existing and unrelated: the Pi terminal-theme
palette check (red on clean main, `docs/issues/2026-08-20-003`) and the smoke
palette test's live leftover file (`docs/issues/2026-08-20-001`).

| Item | Outcome |
| --- | --- |
| 1. per-tab rescan in `compose_tab_intents` | Measured and declined. 5 tabs × 20 panes: **109 ms/call**, ~2% of the 5 s sweep interval. |
| 2. stale-state cleanup rescan | Applied. The pane-id column is cut once into `presented_pane_ids`; the per-state-file scan is now one `list_contains_line` call. |
| 3. `build_worktree_tokens` quadratic scans | Measured and declined. 10 roots, distinct basenames (the shape `agent-<hash>` naming produces): **48 ms/call**. Pairwise basename collisions resolved at two components: **384 ms/call**. Pathological worst case — all ten basenames identical with suffixes probing past the 18-char cap into the digest fallback: **0.7–1.3 s/call**, still inside the 5 s interval and requiring ten same-named checkouts open in panes at once. The cost is dominated by per-comparison subshell/awk spawns, not the scan order, so the `sort \| uniq -c` rewrite would not remove most of it. Revisit only with the record restructuring in `docs/issues/2026-08-20-008-field-separator-positional-record-bus.md`. |
| 4. `count` reused for two meanings | Applied in the minimal form: renamed to `base_matches` and `suffix_components`; the function was not split — the rename alone reads fine. |
| 5. first-value/divergence idiom duplicated | Applied. `track_first_value` (remember first non-empty value, flag a later distinct one) now serves both the repo and the checkout-root bookkeeping; `first_prefix` is captured just before the tracker fills `first_root`. |
| 6. inline tab-segment prefix rule | Applied. `git_ref_segment_for` sits next to `git_ref_for` and names the rule once; the inline branch at the presentation loop is one call now. |

Benchmarks synthesized the issue's own scales (~20 panes, ~10 worktree
roots) against the merged code by sourcing the script's function definitions;
numbers are per call on this machine, 10-iteration averages.
