---
title: readRunUsage exists twice — shared in lib/cost.ts and private in se-pipeline.tsx
type: chore
date: 2026-08-14
status: open
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
