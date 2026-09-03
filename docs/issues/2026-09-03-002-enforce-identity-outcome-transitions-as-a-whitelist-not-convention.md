---
title: "Enforce identity outcome transitions as a whitelist, not convention"
short_description: "herdr-worktree-identity's outcome state machine (docs/plans/2026-09-03-0043-feat-worktree-task-naming-plan.md, stateDiagram-v2 lines 203-222) should reject any from->to pair not in that diagram at runtime, using shuckster/statebot-sh as the cross-platform (POSIX sh, no bash-4 declare -A dependency) chart/dispatch mechanism layered on the plan's own per-worktree storage rather than the library's shared /tmp CSV."
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
`workspace_only`, `declined`, with a fixed set of legal edges between them. Today that diagram is
documentation only — U1/U5's approach (state file writes gated by ad-hoc bash conditionals) relies
on code-review discipline to keep every write on a legal edge.

The predecessor engine's defect history is exactly this failure class: `docs/issues/2026-09-02-011-herdr-task-sync-gives-up-on-worktree-identity-after-a-200-ms-claim-bound-silently.md`
and the five other 2026-09-02 debug findings included silent `return 0` bails at decline sites —
a missed or wrong branch in the state dispatch that nothing caught until a live session hit it. The
whole point of R9/R10 (every decline writes a diagnostic; diagnostics never become a terminal
outcome) is to design that class out. An unenforced diagram is still one missed `case` arm away
from repeating it.

## Scope

Encode the diagram's edges as an explicit whitelist in `home/dot_local/lib/herdr-worktree-state.sh`
(U1) that every state write in the engine (U2-U5) goes through:

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
  of the already-planned per-worktree state file (KTD4) and claim library (U1).
- Any write attempting an edge not in the chart fails loudly instead of silently landing — turning
  a missed case into an immediate, loud bug instead of a silent divergence discovered later.
- This is a design-improvement idea for U1 and U5 to pick up during implementation, not a defect in
  the current plan draft; it does not block the plan's readiness.

## Open decisions

- Whether the whitelist check lives in a single shared function (`assert_legal_transition`) called
  by every write site, or is inlined per call site — the former is easier to keep in sync with the
  diagram as it evolves.
- Whether a transition attempt that fails the whitelist should abort the whole naming event (loud
  failure) or record a diagnostic and no-op (consistent with R9's "no silent bails" but arguably too
  quiet for what would be a programming error rather than expected runtime contention).
