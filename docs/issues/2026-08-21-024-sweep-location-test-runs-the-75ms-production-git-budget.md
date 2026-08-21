---
title: The sweep location-repair test ran its git probes on the 75 ms production budget
type: bug
date: 2026-08-21
status: done
closed: 2026-08-21
---

## Why this exists

`herdr-task-sync sweep repairs process and CWD changes through the presentation
coordinator` (`tests/scripts.bats`) failed twice on CI macos jobs on 2026-08-21,
at two different assertions with one signature — the process-label repair
succeeded while the **worktree location token** did not:

- run `32469269551` (09:49): first-pass assertion, `tokens.worktree` expected
  `old`, actual `null`;
- run `32473218810` attempt 1 (10:46, PR #33 whose diff is Brewfiles and docs):
  post-sweep assertion, expected `new-worktree`, actual `old` — while the
  `cargo test` label assert on the line above passed.

Root cause: the engine's git location probe runs under
`LOCATION_GIT_BUDGET="${HERDR_TASK_SYNC_GIT_BUDGET:-0.075}"` with a `kill -9`
watchdog (`home/dot_local/bin/executable_herdr-task-sync`,
`run_budgeted_command`). A probe that loses the 75 ms race is killed and the
pane degrades to `location_status=stale` — by design, the next pass repairs it.
The harness knows this: `HTS_GIT_BUDGET` (2 s) exists exactly to keep stub
probes inside the budget, and `hts_location_pass` applies it to every location
test. But this test called bare `hts_event_run` for its first pass and
`hts_sweep_run` for its second, and neither carried the calibrated budget — so
both passes ran a forked bash-stub git (awk over a registry plus marker writes)
against the 75 ms production bound. On a loaded `--jobs 8` CI runner the stub
loses that race; on an idle host it never does, which is why the flake is
CI-only.

This is the third missed call site of the wall-clock pattern
`docs/issues/2026-08-21-015` names: the first two 75 ms/5 s idle-calibrated
bounds were fixed in `543ca9e` and `7f675e1`; the sweep path kept the
production budget.

## Scope

- `tests/scripts.bats` — `hts_sweep_run` and the sweep location-repair test.

## Resolution

Fixed in the same change that files this issue.

- `hts_sweep_run` now defaults `HERDR_TASK_SYNC_GIT_BUDGET` to `HTS_GIT_BUDGET`
  the same way `hts_location_pass` does; an explicit env override still wins,
  so the deliberate stale-path tests keep their knob.
- The test's first pass uses `hts_location_pass` instead of bare
  `hts_event_run` + quiescence wait — identical semantics plus the budget.
- Assertions are unchanged and as strict as before; no retries, no skips.

This is a budget correction, not a timeout widen-to-hide: the root cause
genuinely is a too-tight bound — a UI-latency budget calibrated against real
git on an idle machine, applied to a test stub under CI load.

Verification: the CI failure reproduced **verbatim** on the pre-fix file by
starving the budget (`HERDR_TASK_SYNC_GIT_BUDGET=0.0001` → `expected: old,
actual: null`, byte-identical to run 32469269551's block), proving killed
probe → missing/stale worktree token; the fixed test passes 15/15 focused
repetitions and two full `bats --jobs 8 --no-parallelize-across-files
tests/scripts.bats` runs (196 ok, 0 failures each); the override knob still
reaches the engine (starved budget still fails, as the stale-path tests
require); `make lint` clean.
