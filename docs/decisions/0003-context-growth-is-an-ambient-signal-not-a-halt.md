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

Underneath all three sat an assumption worth naming: that the goal of a compaction has to be
known before the compaction. Everything the hook did — extracting a goal, storing it, refreshing
it on a cadence, rendering it — existed to have an answer ready in advance.

## Considered options

- **Keep the halt, make the thresholds a share of the window.** Fixes the 1M false positive and
  nothing else. A peer consult still deadlocks, and the cost signal still arrives as an
  interruption at a moment chosen by a threshold.
- **Keep the halt, exempt herdr children.** Fixes the deadlock only. The operator still gets no
  view of what the session costs between announcements.
- **Drop the halt; keep the goal in state and offer a ready compaction command in the status
  line.** Removes the interruption, but keeps the machinery: a subprocess extracting a goal
  every ten turns, two state files, a cadence, and a truncation rule for drawing the goal in a
  terminal — all so that a command is pre-written for a moment that may never come.
- **Drop the halt and the goal state; let the compaction hook name the goal when it runs.** The
  `PreCompact` hook already receives every compaction and already forks the session to build a
  handoff. That fork resumes the whole session, so it is better placed to say what the session
  was doing than anything measured turns earlier from a transcript tail.

## Decision

The Stop hook is removed, along with the goal state, the thresholds, and the refresh cadence.

The `PreCompact` handoff builder acts on every compaction. `/compact <goal>` names the goal;
a bare `/compact` leaves the `<goal>` block to the fork, which is told to read the session and
name the goal itself. The `handoff:` prefix that used to be the trigger is stripped rather than
required, so a session that still types it is not handed the marker as part of its goal.

The status line keeps one thing from the abandoned design: the load in tokens beside the
percentage. A percentage alone hides the cost on a large window — 190k tokens read as 19% while
every turn is billed for all of them. Both figures come from the same quantity, occupancy plus
the system-prompt allowance, so the printed figure divided by the window is the printed
percentage. Nothing else is rendered and nothing is stored between turns.

The cost accepted is a `haiku` fork on every compaction, with `PreCompact` blocking for up to
its declared 120 seconds. Automatic compaction is disabled in these settings
(`autoCompactEnabled: false`), so this is paid only when the operator asks for a compaction.
