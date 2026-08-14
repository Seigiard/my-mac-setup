---
title: se flow stalls after staging without running any block, and the epilog is partial
type: bug
date: 2026-08-14
status: open
parent-plan: docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md
---

# se flow stalls after staging without running any block, and the epilog is partial

## Why this exists

Host verification section 4 could not be executed. Attempting it surfaced one blocker and four absent features. Sections 2 and 3 of `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` are blocked on the same set.

### The interpreter had never run at all

`se flow` rejected every launch at workflow construction:

```
code: INVALID_INPUT
Output schema for "outcome" uses reserved field name(s): runId.
```

smithers reserves `runId`, `nodeId` and `iteration` as internal columns on every persisted node output. `se-flow.tsx` declared `outcome.runId`, so the engine refused the workflow before any node ran. Fixed in `de81825` by renaming the field to `flowRunId`.

Worth noting for anything else built this way: `bun build` cannot catch this class of error. It resolves the module graph without type-checking and never instantiates the workflow, so a green build says nothing about whether a run can start. Every claim of "the interpreter is structurally complete, its module graph resolves" rested on exactly that check.

### It now starts, and stalls

`run-1786702018234`, a compute-only spec of three blocks (`commit-work` → `run-validate` → `secret-scan`) against a throwaway fixture repo:

- `gate0` completes.
- `staging` completes — the worktree and run branch `se/interpreter-resume-probe-02018234` are created.
- The run then enters `waiting-event` and never renders a block. The `block_output` table has no rows for the run. A `smithers up --resume` does not advance it; it returns to `waiting-event`.

Not diagnosed. The render adds block children under `readyGate = workspaceNeeded ? staged : gate0`, and `staged` should be populated on the tick after staging. Two things to look at first: the launcher logs `Each child in a list should have a unique "key" prop. Check the render method of Sequence`, so the children arrays may not be well formed for the scheduler; and the agent and subflow branches place a bare `null` inside a `<Sequence>` when the dispatch row is not yet present, which may not be a legal child.

### Four features the checklist assumes, which are not written

- **`se flow salvage <runId>`** (U5, KTD10). Zero occurrences of `salvage` in `bin/executable_se`. Section 4.2 tests it.
- **Budget-ceiling parking** (KTD9). `budgetUsd` reaches `makeAgent` as a per-agent cap, and a `budget` output key is declared, but there is no budget compute task and no park branch anywhere in `se-flow.tsx`. A breach cannot park a run because nothing measures it. Section 4.3 tests it.
- **`artifactsFrom` delivery** (R9). The validator checks the archive exists (`flow-validate.ts:175`) and normalisation carries the field, but no code reads a prior run's manifest or hands artifacts to any block. The handoff is validated and never performed. Section 4.4 tests it.
- **Artifact archiving** (KTD10). The epilog creates `$TMPDIR/se-flow/<runId>/` and writes `outcome.json` into it, then copies nothing. The `proof-artifacts` manifest is never read. The directory is an archive in name only.

### Two more epilog gaps

- **No publication-time secret scan** (KTD13b). The epilog writes the outcome record with a plain `fs.writeFileSync`. Nothing scans the record, the issue text, or a PR body before it is written or pushed.
- **The terminal reviewer is a stub** (R14, R15, U6). The `reviewer` epilog node is a deterministic compute task calling `classifyDisposition`; it is not the agent block the plan specifies, and `issue-writer.ts` is never called from anywhere in `se-flow.tsx`. No run can produce a `docs/issues/` file. Section 3's entire pass criterion is that an injected failure yields one, so section 3 cannot pass until this exists.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-flow.tsx` — the stall, the epilog, the missing budget node, the missing artifact copy, the missing secret scan, the stub reviewer.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — `se flow salvage`.
- `docs/plans/2026-08-13-002-dynamic-flow-composition-host-verification.md` — sections 2, 3 and 4 stay unrunnable until the above lands.

## Open decisions

- **Diagnose the stall before building anything else.** Every other item is unverifiable while no block executes, so this is the only ordering that lets a fix be proven rather than asserted.
- **Whether the reviewer stays a compute classifier or becomes the agent block** the plan specifies. The compute version cannot write a cause analysis, which is what R15 asks for; the agent version costs a leg on every run, including clean ones.
- **Whether a build-time check can catch reserved-field and schema errors** so the next one is not found by a failed launch. A test that merely imports and instantiates the workflow would have caught this one.
