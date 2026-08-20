---
title: Label-system test gaps and a hand-duplicated icon table in the bats suite
type: follow-up
date: 2026-08-20
status: open
parent-plan: docs/plans/2026-08-20-001-feat-herdr-label-system-plan.md
---

## Why this exists

The `$git_ref` label system landed with substantial new coverage in
`tests/scripts.bats` and `tests/smoke.bats`. Several paths the plan's scenario
matrix and design decisions depend on are still unexercised, and one test-side
construct reintroduces the exact risk the plan warns about.

**Duplicated icon table.** `home/dot_local/bin/executable_herdr-task-sync:51-59`
defines five codicon glyphs from octal UTF-8 sequences, with this comment: "Raw
PUA glyphs are easily lost when the file passes through editors or agents, so
none may appear verbatim in this script." `tests/scripts.bats:878-882`
independently retypes the identical octal literals as `HTS_ICON_*` rather than
deriving them from the engine. Nothing detects a drift between the two tables:
if the engine's table changes, the suite keeps asserting the old bytes and still
passes.

**Untested paths.**

- The workspace-name fallback. `home/dot_local/bin/executable_herdr-task-sync:1139`
  reads `(.label // .name // "")`, and the comment says `name` exists as a
  fallback for older snapshot shapes. All eight `hts_set_workspace` call sites in
  the new tests pass `label`, so the `name` half is dead as far as the suite can
  tell.
- The three-or-more-pane multi-repo prefix path. `first_repo` / `multiple_repos`
  / `segment_repo` tracking (lines 1448-1457) is only exercised through the
  two-pane branch. No test puts three or more panes from two distinct
  repositories in one tab.
- A detached HEAD inside a linked worktree, where the commit icon deliberately
  wins over the worktree icon.
- A main checkout whose folder name differs from both the branch and the
  workspace label, which is where the implemented folder-qualifier rule and the
  plan's decision 5 disagree (see Open decisions).
- The detached-HEAD SHA-probe failure on a pane with no prior state. When the
  first `git rev-parse` succeeds but the second `--short=7` call exceeds
  `LOCATION_GIT_BUDGET`, the code at line 767 falls back to `prior_*` values and
  discards the freshly resolved root, anchor, and repo. With no prior state file
  the pane renders with no git location for that pass. It self-heals on the next
  sweep.
- Any run under a non-UTF-8 locale. `text_length` uses `wc -m` and `text_prefix`
  uses `cut -c`; under `LC_ALL=C` both count bytes, so each three-byte codicon is
  charged three columns and an 18-character cap can cut a non-ASCII branch name
  mid-codepoint. The daemon inherits its locale from the invoking hook, which was
  not established.

The plan's implementation unit U5 promised "one formatter test per scenario
matrix row (9 cases)". The mapping is not literally one-to-one: rows 3 and 5
share tests, and rows 8 and 9 share tests. Row 2 (worktree where folder equals
branch) has token-level coverage but no single test asserting the sidebar token
and the tab label together.

The 80-column gap for multi-repo tabs is a real defect and is filed separately
as `docs/issues/2026-08-20-004-tab-repo-prefix-breaks-column-budget.md`.

## Scope

- Derive `HTS_ICON_*` in `tests/scripts.bats` from
  `home/dot_local/bin/executable_herdr-task-sync` at `hts_setup` time instead of
  retyping the octal literals.
- Add the missing cases listed above. Each is a small addition to the existing
  bats helpers; none needs new infrastructure.
- Decide whether row 2 deserves its own combined sidebar-plus-tab assertion, or
  whether the existing token-level coverage is enough.

## Open decisions

- Plan decision 5 says a repo-root main checkout gets "branch icon + branch, no
  folder ever". The implemented rule at line 1334 suppresses the folder qualifier
  only when the worktree token equals the ref or the workspace name, so a main
  checkout in a differently-named folder still gets a folder qualifier. Either
  add a third suppression arm for the main-checkout case, or reword decision 5 so
  it describes the typical case rather than promising "no folder ever".
- Whether a non-UTF-8 locale is worth testing, or whether the script should
  instead pin `LC_ALL` for its own width math so the question cannot arise.
