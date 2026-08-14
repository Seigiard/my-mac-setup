---
title: No test instantiates the workflows, so schema errors are found by a failed launch
type: follow-up
date: 2026-08-14
status: done
closed: 2026-08-14
parent-plan: docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md
---

# No test instantiates the workflows

## Why this exists

`se flow` rejected every launch for its whole first day of existence:

```
code: INVALID_INPUT
Output schema for "outcome" uses reserved field name(s): runId.
```

The smithers engine reserves `runId`, `nodeId` and `iteration` as internal columns on every persisted node output. `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` declared an output field named `runId`, so the engine refused the workflow before any node ran. Fixed in commit `de81825` by renaming the field to `flowRunId`.

Nothing in the test suite could have caught it. `bun build` resolves the module graph without type-checking and never instantiates the workflow, so a green build says nothing about whether a run can start. The 343 unit tests all exercise pure helpers in `workflows/lib/`; not one calls `createSmithers`. Every claim that "the interpreter is structurally complete, its module graph resolves" rested on a check that cannot see this class of error.

The cost was not the fix — that was one rename. It was that the defect was found by a live launch, at the end of a day of building, rather than in the second it takes to run a test.

This was carried as an open decision inside `docs/issues/2026-08-14-004-se-flow-stalls-after-staging-and-epilog-gaps.md`. It is split out here because it is actionable now, while issue 004's remaining gap waits on an operator decision about opening a live PR.

## Scope

Add a test that imports each workflow file and instantiates it, asserting only that construction does not throw.

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx`
- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`
- The subflow workflows the two import: `se-code-review.tsx`, `se-doc-review.tsx`, `se-simplify.tsx`

The check is cheap and belongs in the same `bun test` run as the rest.

What it catches: reserved output field names, malformed output schemas, and anything else the engine validates at construction.

What it does NOT catch: the `bind={undefined}` park that cost the same day (recorded in issue 004). That defect only appears once a node is scheduled, so it still needs a live compute-only smoke run. Do not let a green instantiation test be read as "a run will work".

## Open decisions

None. The environment question below is answered.

## Resolution

`home/private_dot_claude/dot_smithers/workflows/workflow-construction.test.ts` imports all five workflow files and asserts each has a default export. Six tests, part of the ordinary `bun test` run from the source directory; the suite is 352 pass / 0 fail.

An import is the whole check, and that is not a shortcut. `createSmithers` validates output schemas eagerly, inside the call that every workflow file makes at module load, so a reserved field name throws before any node exists. Confirmed directly: `createSmithers({ input: …, bad: z.object({ runId: z.string() }) })` throws `Output schema for "bad" uses reserved field name(s): runId`.

The environment question is answered: no variables are needed. All five modules import with none set — `se-pipeline.tsx` falls back to `process.cwd()` for `PIPELINE_REPO`, and nothing else reads the environment at module load.

The test was verified against the original defect rather than assumed to work. Re-introducing the reserved field in `se-flow.tsx` — renaming `outcome.flowRunId` back to `outcome.runId` — turned the suite red on exactly the `se-flow.tsx` case and nothing else. The mutation was reverted immediately; `git status` on the file is clean.

One test in the file is a canary rather than a check of our own code: it asserts that `createSmithers` still rejects a reserved field. If a future engine version stops validating eagerly, the five import tests would quietly stop checking anything, and the canary is what would say so.

The limit stated in the Scope section holds and is written into the test file's own comments: this proves a workflow is constructible, never that a run advances.
