---
title: readRunUsage exists twice — shared in lib/cost.ts and private in se-pipeline.tsx
type: chore
date: 2026-08-14
status: done
closed: 2026-08-14
---

# readRunUsage exists twice

## Why this exists

Two copies of the same ~35-line reader of `TokenUsageReported` events now exist:

- `home/private_dot_claude/dot_smithers/workflows/lib/cost.ts` — the shared, unit-tested one, behind an injected database opener. Used by `se-flow.tsx`.
- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — a private copy, predating the shared one.

The duplication was deliberate, not an oversight. `se-pipeline.tsx` is the rollback path the dynamic-flow plan holds untouched, and changing its statically-imported module graph invalidates the resume of any parked pipeline run (KTD1). Switching it over would also have meant re-running the section 5 regression to prove nothing moved — about 30 minutes and ~$1.50 — for a refactor with no behaviour change.

The risk is ordinary drift: a fix to one copy that never reaches the other. The shared copy is the one with tests.

## Scope

Fold `se-pipeline.tsx` onto `lib/cost.ts`'s `readRunUsage` the next time that file is edited for another reason, so the module-graph change and the regression run are paid for once rather than twice.

Preconditions for doing it: no pipeline run in `running` or `waiting-approval` (`se list`), and the section 5 regression re-run afterwards.

## Open decisions

None. This is a mechanical fold, deferred for cost rather than uncertainty.

## Resolution

Folded in commit `050d421`. `se-pipeline.tsx` now calls `readRunUsage` from `workflows/lib/cost.ts` and its private copy is gone.

A second duplicate this issue did not name was folded at the same time: `se-flow.tsx` held the only production database opener, `openUsageDb`, privately. It moved into `lib/cost.ts` beside the reader it feeds, so both workflows and the unit tests share one code path. `se-flow.tsx` no longer imports `bun:sqlite`. Net change: 43 lines deleted.

Preconditions were met before the edit: `se list` showed no run in `running` or `waiting-approval`, so no parked run's resume was invalidated by the module-graph change.

Equivalence was checked against real data rather than by inspection. A scratch script ran the deleted reader, recovered verbatim from git, alongside the shared one over the live event log: 28 run ids plus one nonexistent id, zero mismatches in the aggregated result. Three new unit tests cover the opener itself against a real sqlite file, a zero-byte file, and a missing path; the library suite is 343 pass / 0 fail.

The section 5 regression this issue required was re-run: `run-1786712975751`, verdict green, 2,860,152 tokens, ~$1.53, `bun test` on the run branch 4 pass / 0 fail. A non-zero cost figure is the load-bearing observation — the reader fails soft, so a broken fold would have reported 0 tokens and $0 instead of raising.
