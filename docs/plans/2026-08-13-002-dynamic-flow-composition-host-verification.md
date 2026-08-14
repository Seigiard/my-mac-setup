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
se blocks --json | jq -r '.blocks[].name'
se flow <spec.json> --dry-run
```

Pass criteria: the catalog lists the initial block library, and the dry-run prints the composed flow with its cost estimate without launching anything.

## Recording the result

A gate that passes is recorded in the plan's Definition of Done. A gate that fails becomes a `docs/issues/` entry naming the scenario number from this file, so the failure is traceable back to a specific claim rather than to "the pipeline broke".

## Results

### Section 5 — regression: PASSED, 2026-08-14

`run-1786700241899` on a fresh `make-pipeline-fixture.sh` repo. Verdict green, branch `se/fixture-reverse-plan-00241899`, 2,351,100 tokens, ~$1.46. The baseline run before any of this work, `run-1786539437958` on the same fixture, was also green at ~$1.46 — same verdict, same cost, same shape.

The pipeline did real work rather than passing vacuously: the branch adds `src/reverse.ts` and `src/reverse.test.ts`, and `bun test` on that branch is 4 pass / 0 fail. Simplify skipped itself through its right-sizing classifier, which is its documented behavior on a diff this small.

One waive was needed, for a cause outside this plan: the opencode review leg reported status `findings`, which is absent from the terminal-status allowlist, so a healthy leg carrying a well-formed P3 was counted as failed and the gate degraded. Tracked in `docs/issues/2026-08-14-002-review-leg-status-allowlist-false-failures.md`. It is not a regression — the baseline run's leg happened to say `completed`, a word that is on the list.

### Section 6 — skill deployment: PARTIAL, 2026-08-14

`se blocks --json` from the deployed copy emits the 13-block catalog, and the new `publishes` flag reads true for `pr`, confirming the scan-before-publish invariant reached the live tree. `se flow <spec> --dry-run` assembles the workflow input and prints the command without launching, on a five-block bug-shaped spec.

**The second pass criterion is not met.** The dry-run prints only `FLOW_REPO` and the `smithers up` command line. It does not print the ordered block list with the summed cost estimate that R10 requires and that U5 assigns to the flow printout. The feature is absent, not broken — `se flow` has no printout code. Section 6 cannot be closed until it exists.
