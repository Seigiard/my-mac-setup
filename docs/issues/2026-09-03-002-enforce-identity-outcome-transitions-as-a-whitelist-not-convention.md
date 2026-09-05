---
title: "Enforce identity outcome transitions as a whitelist, not convention"
short_description: "The outcome state machine in docs/plans/2026-09-03-0043-feat-worktree-task-naming-plan.md (stateDiagram-v2 lines 203-222) is still documentation only now that the plan has shipped (64f42fe, cfe2e40): no whitelist exists, write_identity_state (executable_herdr-worktree-identity:289-301) accepts any outcome string from ad-hoc branches, and the shipped vocabulary already diverges from the diagram (hyphenated workspace-only and workspace-failed, undocumented workspace-prepared and branch-failed, pending never written, contended only a diagnostic), so reconciling the chart precedes encoding it as a runtime whitelist via shuckster/statebot-sh chart dispatch over the per-worktree state file rather than the library's shared /tmp CSV."
type: "idea"
category: "herdr"
tags: ["herdr-worktree-identity","state-machine","design-improvement"]
date: "2026-09-03"
status: "open"
priority: "medium"
---

## Why this exists

The plan at `docs/plans/2026-09-03-0043-feat-worktree-task-naming-plan.md` documents the outcome
state machine for `herdr-worktree-identity` as a `stateDiagram-v2` (lines 203-222): `pending`,
`contended`, `unresolved`, `prepared`, `attribution_failed`, `complete`, `workspace_failed`,
`workspace_only`, `declined`, with a fixed set of legal edges between them.

That plan has since shipped (`64f42fe` #155, `cfe2e40` #166), and the diagram is still
documentation only. No whitelist exists anywhere: `grep -rn statebot home/ tests/ scripts/ docs/`
returns nothing outside this record, `home/dot_local/lib/herdr-worktree-state.sh` (194 lines)
holds only encode, atomic-write, and read-field primitives, and
`write_identity_state()` (`home/dot_local/bin/executable_herdr-worktree-identity:289-301`)
accepts any `outcome` string from ad-hoc branches (`:390`, `:395`, `:401` declined; `:535`
attribution_failed; `:584`, `:616`, `:627` desired_outcome; `:572`, `:595`, `:600`, `:607`,
`:633` workspace-failed). So this is now a retrofit onto live code, not a design note for
implementation to pick up.

The shipped vocabulary also diverges from the diagram, and that has to be reconciled before any
chart is encoded:

- The engine writes hyphenated names the diagram spells with underscores: `workspace-only`
  (`:832`, `:844`) and `workspace-failed`, against the diagram's `workspace_only` and
  `workspace_failed`.
- The engine writes two outcomes the diagram does not list at all: `workspace-prepared`
  (`:611`) and `branch-failed` (`:811`).
- `pending` is never written as an outcome.
- `contended` is not an outcome. It appears only as a diagnostic through `record_diagnostic`
  (`:729`, and `lifecycle-contended` at `:873`).

The predecessor engine's defect history is exactly this failure class: the 2026-09-02 debug
findings included silent `return 0` bails at decline sites — a missed or wrong branch in the
state dispatch that nothing caught until a live session hit it. (The issue record that documented
the 200 ms claim-bound bail was removed in the closed-issue cleanup, and its ID `2026-09-02-011`
has since been reused for an unrelated record, so it is no longer citable.) The whole point of
R9/R10 — every decline writes a diagnostic; diagnostics never become a terminal outcome — is to
design that class out. An unenforced diagram is still one missed `case` arm away from repeating it.

## Scope

Reconcile the diagram with the shipped outcome set, then encode its edges as an explicit whitelist
in `home/dot_local/lib/herdr-worktree-state.sh` that every state write in the engine goes through:

- Settle the naming and membership questions first (hyphen versus underscore; whether
  `workspace-prepared` and `branch-failed` are real states or intermediates; whether `pending`
  should exist). Encoding the current diagram as written would reject most live writes.
- Adopt `shuckster/statebot-sh` as the whitelist mechanism: its declarative `from -> to` chart plus
  `case_statebot`-style dispatch rejects any transition not listed in the chart. It is plain POSIX
  sh, so it runs unmodified on both targets this repository ships to — macOS's system `/bin/bash`
  3.2 and Linux CI/Docker — with no dependency on bash-4-only features like `declare -A` (a
  `declare -A`-based associative-array table was the alternative considered; it would silently break
  under bash 3.2 when a non-interactive hook's `PATH` has not yet picked up Homebrew's bash 5).
- Do **not** adopt the library's own persistence (`statebot_init`/`statebot_emit`, backed by a
  single shared `/tmp/statebots.csv` with no cross-process locking) — that would reintroduce the
  exact shared-file contention class that KTD4 (one per-worktree state file, one repository-scoped
  claim) was designed to avoid. Use only its chart/dispatch layer for transition validation, on top
  of the shipped per-worktree state file and claim library.
- Any write attempting an edge not in the chart fails loudly instead of silently landing — turning
  a missed case into an immediate, loud bug instead of a silent divergence discovered later.

## Open decisions

- Which spelling and membership the reconciled chart uses, given the four divergences listed above.
- Whether the whitelist check lives in a single shared function (`assert_legal_transition`) called
  by every write site, or is inlined per call site — the former is easier to keep in sync with the
  diagram as it evolves.
- Whether a transition attempt that fails the whitelist should abort the whole naming event (loud
  failure) or record a diagnostic and no-op (consistent with R9's "no silent bails" but arguably too
  quiet for what would be a programming error rather than expected runtime contention).
