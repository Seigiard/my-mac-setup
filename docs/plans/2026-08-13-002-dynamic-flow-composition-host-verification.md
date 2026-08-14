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

### Section 1 — engine spike: PASSED, all four scenarios, 2026-08-14

Run on a throwaway two-file spike — a workflow that maps input items to tasks, plus an imported helper that exists only as the edit target for scenario 1.4. Both files were removed from the live tree afterwards, per the plan's cleanup criterion. No agent legs, so the whole section cost nothing.

**1.1 hash stability.** Two launches, inputs `["a","b"]` and `["x","y","z"]`, so the rendered tree differed in size. Both rows in `_smithers_runs` carry the identical `workflow_hash` `1746bf93…4a169ae` and the identical `entryWorkflowHash` `3b31ec12…d0af766c`. Workflow identity follows the module graph, not the render — which is the assumption KD2 rests on.

**1.2 kill and resume.** Six sequential tasks, killed mid-run with three completed. Each task records `Date.now()`, so re-execution is directly visible. After resume the first three timestamps were byte-identical to their pre-kill values and only the remaining three were new, 58 seconds later. Zero completed tasks re-executed.

**1.3 Approval inside a dynamic subtree.** The approval node is generated inside the `map` over input items, not placed beside it. The run parked at `approve:gate-b`, the two ungated tasks completed, the gated one did not. After `se approve` and resume the run finished, the gated task ran, and the two already-completed tasks kept their original timestamps.

**1.4 edit under a parked run.** With a run parked, `spike-helper.ts` was edited — an *imported* file, not the workflow entry file. Resume refused: `Cannot resume run because durable metadata changed … resume hashes the workflow file content, not git`. This proves the KTD1 zero-in-flight rule rather than assuming it, and it establishes something stronger than the scenario asked: the durability hash covers the imported module graph, so editing any block or shared lib under a live run is equally fatal, not just editing the interpreter.

One incidental finding, worth knowing before writing any future compute block: a task closure that blocks the event loop — the first spike used `spawnSync("sleep")` — prevents the engine from persisting *any* completed task. Two kill-and-resume attempts lost all work before the cause was clear. Compute effects that shell out should stay short, or the run loses its resume point.

### Section 3 — live end-to-end, failure path: PASSED on three of four criteria, 2026-08-14

Run against a throwaway fixture repo with a compute-only spec whose last block genuinely fails (`secret-scan` on an empty commit range). The failure is real, not injected, which is stronger evidence than a stub.

**The issue file criterion passes.** `run-1786704530349` wrote `docs/issues/2026-08-14-001-flow-run-failed-at-block-scan-secret-sca.md`. It names the failed block in its title and in a `**Failed block:**` line, states the cause, and quotes the log excerpts with the failed block first. The reviewer's analysis was correct and, where the evidence ran out, said so: *"Whether the pipeline expected check/proof to create a commit before scan ran is unknown from the evidence available."*

**The redaction criterion passes.** `run-1786704594258` planted `AKIAIOSFODNN7EXAMPLE` in the validate-cmd output, where it reached a block payload and then the issue file. The literal key appears zero times in the written file. It was redacted in two places: the log excerpt, and the reviewer's own prose, where the model quoted the key back while explaining it. That second hit is the argument for redacting the rendered file rather than only the excerpt — an excerpt-only scan would have published it.

That run also exposed an over-redaction: the assigned-secret pattern ran past the key and ate the next log line, because inside a JSON payload a newline is the two characters `\n`, not whitespace. Fixed by stopping the value at a backslash; real secrets carry none.

**The daily sequence works.** Three runs produced `-001-`, `-002-`, `-003-` on the same date.

**The archive criterion does not pass, and is not a reviewer problem.** The outcome record exists at `$TMPDIR/se-flow/<runId>/outcome.json`, but nothing copies the `proof-artifacts` manifest into that directory. Tracked as the artifact-archiving item in `docs/issues/2026-08-14-004-...`.

**The dead-leg criterion is unit-verified only.** `classifyDisposition` and `parseReviewerVerdict` cover it, and `run-1786704301055` demonstrated the guard path for real when the reviewer leg itself failed — the catch recorded a no-verdict row and cleanup still released the worktree and the repo lock. No live run has yet killed a *block* leg mid-stream.

One path was never reached: clean success with no issue file. The reviewer legitimately found an actionable optimization on every green run of this fixture — on `run-1786704670473` it noticed the repo's implementation-ready plan was never implemented while the flow still reported green. Correct behaviour, but it means the no-file branch stays unit-tested only.

### Section 5 — regression: PASSED, 2026-08-14

`run-1786700241899` on a fresh `make-pipeline-fixture.sh` repo. Verdict green, branch `se/fixture-reverse-plan-00241899`, 2,351,100 tokens, ~$1.46. The baseline run before any of this work, `run-1786539437958` on the same fixture, was also green at ~$1.46 — same verdict, same cost, same shape.

The pipeline did real work rather than passing vacuously: the branch adds `src/reverse.ts` and `src/reverse.test.ts`, and `bun test` on that branch is 4 pass / 0 fail. Simplify skipped itself through its right-sizing classifier, which is its documented behavior on a diff this small.

One waive was needed, for a cause outside this plan: the opencode review leg reported status `findings`, which is absent from the terminal-status allowlist, so a healthy leg carrying a well-formed P3 was counted as failed and the gate degraded. Tracked in `docs/issues/2026-08-14-002-review-leg-status-allowlist-false-failures.md`. It is not a regression — the baseline run's leg happened to say `completed`, a word that is on the list.

### Section 6 — skill deployment: PASSED, 2026-08-14

`se blocks --json` from the deployed copy emits the 13-block catalog, and the new `publishes` flag reads true for `pr`, confirming the scan-before-publish invariant reached the live tree.

`se flow <spec> --dry-run` now prints the ordered block list with its cost estimate and launches nothing, which closes the criterion this section was previously blocked on. On a two-block spec with one agent leg:

```
flow: cost estimate probe
2 blocks, estimated ~$20, up to ~$40 if every block exhausts its retries
   1. fix   work         agent          ~$20
   2. scan  secret-scan  compute        ~$0
```

The retry-ceiling total is the useful half — it is what an operator needs before approving a launch, and a per-block estimate alone hides it.

The printout also validates the spec and refuses to print an invalid one, exiting non-zero with the validator's errors. A spec missing explicit `retries`/`timeoutMs` was rejected before launch during this session's testing, which is the intended behaviour: printing a plan for a flow that gate-0 would refuse would promise a launch that cannot start.
