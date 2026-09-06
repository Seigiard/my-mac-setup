---
title: "Enforce identity outcome transitions as a whitelist, not convention"
short_description: "Resolved: the nine legal outcomes are now a whitelist in herdr-worktree-state.sh that write_identity_state enforces, spellings standardized on hyphens (attribution_failed renamed, legacy value still accepted on read), workspace-prepared and branch-failed admitted, pending and contended excluded, and the plan's diagram reconciled to match."
type: "idea"
category: "herdr"
tags: ["herdr-worktree-identity","state-machine","design-improvement"]
date: "2026-09-03"
status: "done"
priority: "medium"
closed: "2026-09-06"
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
- The engine's own spelling is mixed, so no whitelist can accept the shipped set unchanged:
  `attribution_failed` (`:535`) uses an underscore while `workspace-failed`, `workspace-only`,
  `workspace-prepared`, and `branch-failed` use hyphens. Whichever spelling the chart adopts,
  at least one live outcome name has to change, or the chart must accept both spellings.
- The plan document contradicts itself. Its prose immediately above the diagram (line 200) names
  the terminal states `complete`, `workspace-only`, and `declined` with a hyphen, while the
  diagram directly below spells the same state `workspace_only`. The underscores are most likely
  a mermaid constraint rather than a naming decision: `-->` is the transition operator in
  `stateDiagram-v2`, so a bare hyphenated state id is ambiguous. That makes "the engine's hyphens
  are correct and the diagram was working around mermaid syntax" the most probable reading,
  but it is still the user's call.

A 2026-09-05 audit enumerated every outcome the engine can write, to confirm the divergence list
is complete: `unresolved` (`:319`), `declined` (`:390`, `:395`, `:401`, `:949`), `prepared`
(`:533`, `:775`), `attribution_failed` (`:535`), `workspace-failed` (`:572`, `:595`, `:600`,
`:607`, `:633`), `workspace-prepared` (`:611`), `branch-failed` (`:811`), `workspace-only`
(`:840`), and `complete`. The last two also arrive through `label_workspace`'s `desired_outcome`
parameter (`:584`, `:616`, `:627`), whose only call sites pass `complete` (`:858`) or
`workspace-only` (`:832`, `:859`, and `:846` via `terminal_outcome`). Nine outcomes in total; no
others exist.

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

## Resolution

Whitelist built and enforced, standardized on hyphens. HERDR_WORKTREE_IDENTITY_OUTCOMES plus is_legal_outcome() live in home/dot_local/lib/herdr-worktree-state.sh; write_identity_state validates there rather than at 22 threaded call sites, since every write already passes through it, and refuses an illegal outcome with an illegal-outcome diagnostic and a nonzero return that callers already handle as a state-write failure. attribution_failed renamed to attribution-failed at its write site, its case branch, and three assertions in tests/bashunit/scripts_test.sh; the case branch and write_identity_state both accept the legacy spelling on read so in-flight cached state is not stranded, while only the canonical spelling is ever persisted. Membership: unresolved, declined, prepared, attribution-failed, workspace-prepared, workspace-failed, branch-failed, workspace-only, complete, plus the empty string for a state written before an outcome is selected. pending excluded (no write site produces it), contended excluded (diagnostic evidence, not an outcome). The plan diagram at docs/plans/2026-09-03-0043-feat-worktree-task-naming-plan.md is reconciled to match, using mermaid state aliases for the hyphenated names. Verified: tests/bashunit/scripts_test.sh 330 passed 1 skipped, make lint clean.
