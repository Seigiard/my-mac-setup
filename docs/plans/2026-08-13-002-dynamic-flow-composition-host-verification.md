---
title: Dynamic Flow Composition — Host Verification Checklist
type: feat
date: 2026-08-13
status: open
topic: dynamic-flow-composition
artifact_contract: operator-checklist/v1
artifact_readiness: operator-checklist
execution: manual
---

# Dynamic Flow Composition — Host Verification Checklist

The companion to `docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md`. That plan holds every requirement, decision, and unit; this file holds only the share of its verification that a staged pipeline worktree cannot run.

`artifact_readiness` is `operator-checklist` on purpose, so `/se-work` never picks this file up as a plan.

## Why this file exists

A pipeline run stages an isolated git worktree under `/tmp`. Three things are missing there, and each one blocks a class of verification:

1. **No Smithers daemon to launch runs against.** Anything that starts a run, kills it, and resumes it is unverifiable.
2. **No authenticated `gh`.** The PR block can be unit-tested against a stub, never against GitHub.
3. **No permission to run `chezmoi apply`.** The host rule in `CLAUDE.md` forbids it, so a skill can be written but not deployed.

Run this checklist on the host, after the implementation branch merges to `main` and `chezmoi apply` has deployed it.

## Preconditions

Every step below assumes all three hold. Check them once, at the start.

```
se list                    # no run in status running or waiting-approval
git -C ~/Projects/my-mac-setup status --porcelain    # empty
gh auth status             # authenticated
```

The first matters most. KTD1's zero-in-flight rule means editing a file in the interpreter's module graph while a run is live or parked breaks that run's resume. This checklist edits such files in step 4.

## 1. Engine spike (U0)

Four scenarios. A negative result on any of them reopens KD2 with the operator and invalidates U4's design — report it rather than working around it.

| # | Scenario | Pass criterion |
|---|---|---|
| 1.1 | Launch the same workflow twice with different inputs | Both runs report the same workflow identity hash |
| 1.2 | Kill a run mid-block, then `se resume <runId>` | Zero completed tasks re-execute |
| 1.3 | An `Approval` node inside a dynamically generated subtree | The run pauses at it and resumes correctly after `se approve` |
| 1.4 | Edit an imported helper file while a run is parked, then resume | Resume fails with the documented error, proving the KTD1 rule rather than assuming it |

Scenario 1.4 deliberately breaks a run. Use a throwaway fixture run, never real work.

## 2. Live end-to-end, success path (U4, U9)

```
tests/fixtures/make-pipeline-fixture.sh
```

Then launch a bug-shaped flow spec against the fixture repo and let it finish.

Pass criteria, all four:

- The run provisions a worktree and executes its blocks headlessly.
- A PR opens, and its body embeds the secret-scanned spec and the outcome record.
- The outcome record and artifact archive exist under the Smithers state directory, keyed by runId.
- No issue file appears in `docs/issues/` — a clean success writes its review into the outcome record instead.

## 3. Live end-to-end, failure path (U6)

Same fixture, with a block failure injected mid-stream.

Pass criteria:

- An outcome record and artifact archive exist despite the failure.
- `docs/issues/YYYY-MM-DD-NNN-<slug>.md` exists, names the failed block, states the cause, and quotes log excerpts.
- A planted secret in those log excerpts is redacted in the written file (KTD13).
- A leg that died with a non-terminal status is classified as failure evidence, never as clean zero findings.

## 4. Interpreter resume behavior (U4)

Four scenarios against the fixture flow. Scenario 4.4 is the permanent regression gate: run it before `se flow` is used for real work, and again after any change to the interpreter's module graph.

| # | Scenario | Pass criterion |
|---|---|---|
| 4.1 | Hard-kill mid-block, then resume | Zero completed blocks re-execute; deterministic ids match |
| 4.2 | Hard-kill mid-block, no resume, then `se flow salvage <runId>` | A synthesized outcome record the validator accepts for `artifactsFrom` (U5's host share) |
| 4.3 | Drive a run past its budget ceiling | The run parks rather than dying, and reaches the epilog after the operator acks |
| 4.4 | Two runs: terminate run 1 after a research block, then launch run 2 with `artifactsFrom` pointing at run 1's archive | Run 2 validates and its blocks receive the listed artifacts (AE4) |

## 5. Regression: the untouched pipeline (U3)

The whole rollback path of KD6 rests on this. `se-pipeline.tsx` is untouched by the plan, and the existing command must behave identically.

```
tests/fixtures/make-pipeline-fixture.sh
se pipeline <fixture-plan-path>
```

Pass criterion: the fixture run reaches its normal verdict, with no behavior difference against a pre-change run.

## 6. Skill deployment (U7)

```
chezmoi apply
```

Then, from the deployed copy rather than this checkout:

```
se blocks --json | jq '.[].name'
se flow <spec.json> --dry-run
```

Pass criteria: the catalog lists the initial block library, and the dry-run prints the composed flow with its cost estimate without launching anything.

## Recording the result

A gate that passes is recorded in the plan's Definition of Done. A gate that fails becomes a `docs/issues/` entry naming the scenario number from this file, so the failure is traceable back to a specific claim rather than to "the pipeline broke".
