# 3. Context growth is an ambient signal, not a halt

## Context

The context-threshold Stop hook announced context growth to the operator and, at a hard
threshold, returned `continue: false` to stop the session. `docs/plans/2026-09-04-0737-feat-context-threshold-handoff-plan.md`
still describes that design.

Three things were wrong with it.

The halt reached sessions it was never meant to interrupt. A herdr peer consult runs a full
interactive `claude` in its own pane, so `CLAUDE_CODE_ENTRYPOINT` reads `cli` and the headless
exemption did not fire. The halt landed in a pane nobody was reading while the parent blocked
in `herdr-child start --wait` for up to thirty minutes, and `se-code-review` starts two peers
per review.

The token thresholds were derived for a 200k window, where the hard level sits at 95%. On the
1M-window models now in daily use the same figure is 19% — a stop with four fifths of the
window still free.

The thresholds also answered the wrong question. What the operator wanted to see was that the
session had grown expensive enough to be worth compacting, and context is billed on every turn
from the first token. That is a continuous condition, and an interruption has to pick a moment
for it.

## Considered options

- **Keep the halt, make the thresholds a share of the window.** Fixes the 1M false positive and
  nothing else. A peer consult still deadlocks, and the cost signal still arrives as an
  interruption at a moment chosen by a threshold.
- **Keep the halt, exempt herdr children.** Fixes the deadlock only. The operator still gets no
  view of what the session costs between announcements.
- **Drop the halt; carry the signal in the status line.** The status line renders every turn in
  a fixed place, costs no tokens, reaches no model, and has no moment to pick.

## Decision

The hook produces no output at all. It writes one goal into state; the status line reads it and
renders `/compact handoff:<goal>` beneath the context bar, so the command is on screen without
scrolling. The hard threshold, the per-dimension warning budgets, and the shrinking repeat
cadence are removed.

One hint threshold in tokens and one in turns decide only whether the status line has a command
to offer. The goal is refreshed on a fixed turn cadence rather than extracted once, and it is
expected to drift between refreshes: it is a starting point the operator edits, which is what
makes refreshing it affordable.

The status line prints the load in tokens beside the percentage, and both are the same quantity
— occupancy plus the system-prompt allowance — so the printed figure divided by the window is
the printed percentage. The hint thresholds are compared in those same units, so an operator can
read a threshold off the screen.

Herdr children remain exempt from the hook entirely, by the `HERDR_CHILD_NAME` marker their
launcher already sets.
