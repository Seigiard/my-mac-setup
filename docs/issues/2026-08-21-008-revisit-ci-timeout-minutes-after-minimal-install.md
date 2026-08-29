---
title: "Revisit the CI timeout-minutes downward once two weeks of minimal-install runs exist"
short_description: "Recalibrated: test-ubuntu timeout-minutes 15 -> 12 and test-macos 25 -> 20, sized from 9 days of post-minimal-install run data (push/PR minimal and nightly full-Brewfile distributions measured separately)."
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","follow-up"]
date: "2026-08-21"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md"
closed: "2026-08-29"
---

## Why this exists

`.github/workflows/test-dotfiles.yml` sets `timeout-minutes: 15` on `test-ubuntu` and
`timeout-minutes: 25` on `test-macos`. Both were sized against a full-Brewfile install. The
CI-minimal change cuts the `brew bundle` portion of the apply step from a measured 177.9 s to
a handful of packages on ubuntu, and from 383.8 s to the same on macOS, so both ceilings are
now far looser than the work beneath them.

A loose timeout is not free. It is the only thing that bounds a hung apt mirror or a stalled
brew download — the exact failure the ubuntu job's existing comment says the 15-minute value
exists to catch. The looser it is relative to a normal run, the longer a hang burns before
anything notices.

Deliberately not lowered in the same change as the install cut. Two variables at once means a
timeout failure cannot be attributed: it could be a real hang, or a ceiling set from a sample
that did not include a slow runner. The plan's U4 records this as the reason.

Note that scheduled and `workflow_dispatch` runs still install the **full** Brewfiles, so
whatever new ceiling is chosen has to clear the nightly run's duration, not the push/PR run's.
That is the constraint most likely to be missed — the nightly is the slowest run and the
least watched.

## Scope

- Collect two weeks of runs after the CI-minimal change lands. Separate the push/PR runs
  (minimal) from the scheduled and dispatched runs (full); they are different distributions.
- Pick a ceiling per job from the slow tail of each distribution, not the mean. `gh run list
  --workflow test-dotfiles.yml --json databaseId,conclusion,event,createdAt,updatedAt` gives
  the raw durations.
- Consider whether the two run classes want different ceilings. A per-job `timeout-minutes`
  cannot vary by event directly, but a job-level expression can.

## Open decisions

- One ceiling per job sized for the nightly full install, or an event-dependent expression
  that keeps push/PR runs tight? The second bounds hangs better and costs an expression that
  has to stay correct.
- How much headroom over the observed slow tail? The current values are roughly 3× a normal
  run; the comments say "a normal run takes ~5 min" and "~10 min" against 15 and 25.
- Should this wait on `docs/issues/2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md`?
  If the ubuntu job stops running `brew bundle` altogether, or starts putting Linuxbrew on
  `PATH`, its duration changes again and this measurement has to be redone.

## Resolution

Lowered .github/workflows/test-dotfiles.yml timeout-minutes: test-ubuntu 15 -> 12, test-macos 25 -> 20 (commit 8fb43d6). Sized from observed runs 2026-08-21..2026-08-29 via gh run list/view, separating distributions: push/PR minimal installs (test-ubuntu n=31, max 5.3 min; test-macos max 10.7 min) and scheduled nightly full-Brewfile runs (test-ubuntu successes 6.6-7.9 min; test-macos successes 10.8-14.8 min, worst self-completing failure 18.4 min). Chose one event-independent ceiling per job, per this issue's own simplicity bias: 12 is ~1.5x the nightly ubuntu max 7.9; 20 clears the worst observed macos failure 18.4 and is ~1.35x the slow successful tail 14.8. The blocker 2026-08-21-007 (linuxbrew prefix) is done and the sample post-dates it. Caveats recorded honestly: the issue asked for two weeks of data but 9 days were available, judged sufficient because the minimal-run sample is n=31 and stable and the nightly full-run distribution never depended on the CI-minimal change; and the macos margin over the worst self-completing failure is thin (1.6 min), so if a legitimate nightly run is ever timeout-killed near 20 min, raise or split the ceiling by event. Comments in the workflow and the stale cross-reference in tests/helpers/herdr_task_sync.bash were updated to match; cross-model review flagged only record-keeping drift, fixed alongside.
