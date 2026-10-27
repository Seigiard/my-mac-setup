# Failure recovery

The tdd orchestrator's diagnosis routes and candidate preservation, reached from [Responding to a failure](SKILL.md#responding-to-a-failure) in SKILL.md.

## Responding to a failure

Every failed or incomplete settlement gets a **diagnosis** in Verdicts before any reset, restore, or dispatch. A diagnosis carries:

- an ID (`D1`, `D2`, ...), the artifact it concerns, and the affected assertion or boundary;
- a reproduction, the independent expected result, and the authoritative source that settles it, or the missing decision;
- for the **Test preparation** and **Production** rows, the candidate cause and its **cause check**: one observation that comes out differently when the cause is wrong, with the predicted and the observed result, run before the route is chosen. A cause survives when the observed result matches the prediction; the diagnosis is recorded with the first cause that survives. A check that contradicts the cause discards it, and the next candidate cause gets its own check. When no candidate survives, the diagnosis takes the **Capability** row.

One settlement can carry several diagnoses; each takes its own route, in the order [Batches and turns](SKILL.md#batches-and-turns) gives for open findings. Take the **smallest action that fixes exactly the diagnosis**; model escalation is for a child that could not do the work, never for a slip.

| Artifact and diagnosis | Smallest action |
|---|---|
| **Handoff:** the report, a log, or a control artifact is missing, including a report mapping to an existing criterion, and the inspected work looks sound | Resume the same child ([Dispatch](SKILL.md#dispatch)) naming the missing items; a check that never ran is named as a check to run now. Report-only corrections need no commit. An item still missing after one resume is a returned diagnosis. When the child's session is gone, a fresh child on the same tier gets the [preserved candidate](#preserving-a-candidate) and the remaining work. |
| **Test preparation:** a localized defect with a reproduction and a known correct result (a missing `await`, a helper that echoes its input, one wrong fixture) | A **targeted fix** by a test writer on the same tier: its prompt names the preserved candidate ref, the diagnosis, and the paths it may change. It restores those paths from the ref and changes only what the diagnosis names. Full lock acceptance (step 3 in [The chain](SKILL.md#the-chain)) follows. |
| **Not reproduced:** the symptom criterion's faithful test or observation reaches the expected behavior on the production base, as [symptom.md](symptom.md#not-reproduced) defines | Stop and report as `symptom.md` says; the caller decides. |
| **Production:** a localized defect with a reproduction and a known correct result | A **targeted fix** by an implementer on the same tier, continuing from the current branch tip; its prompt names the diagnosis, the paths it may change, and the control that confirms the fix. Full validation (step 5 in [The chain](SKILL.md#the-chain)) follows. |
| **Production:** a changed file or hunk serves no existing criterion | The **Production** targeted fix above, with the diagnosis naming the unrelated paths to remove. |
| **Locked test:** a test is wrong (false green, wrong oracle, contradictory fixture) | The suspect-test route under [Entering mid-chain](SKILL.md#entering-mid-chain), on the tier of the last accepted lock; the re-lock lands before any implementer runs. |
| **Calibration:** a mutation was unfaithful, or restoration failed | Recover and verify the production snapshot at `calibration_sha`, then a fresh calibrate child. The lock stays. |
| **Capability:** an authoritative contract or oracle source already settles the expected result, but the child could not establish the behavior from it, exercise it, or produce a faithful regression | A fresh child one tier up with the diagnosis in its prompt. On `high+`, there is no next tier: stop. |
| **Prerequisite:** the environment or the caller's brief is wrong | The orchestrator corrects run-directory data, brief data, and environment state within its scope. A repository edit goes to a scoped child only when an existing criterion already requires the repair; otherwise return the scope decision to the caller as **Decision**. After each repair, retry the same tier. When it cannot be restored with the tools and access you have, stop. |
| **Decision:** the available authority does not settle the expected result, or sources conflict, a change needs a product decision, or a necessary change violates a non-goal | Ask the caller. No model change answers this. |

A diagnosis **returns**, and stops the chain, when its recorded reproduction still fails after a turn assigned to fix it. A new reproduction is a new diagnosis, which counts against the batch's turns but is not a return.

When a route stops the chain, report its diagnoses, the remaining work, and the run directory to the caller.

### Preserving a candidate

Before any reset, restore, or `git clean`, keep what the child produced reachable as one ordinary commit under `refs/tdd/`[`<run-id>`](run-directory.md#run-directory)/`<role>-<n>`:

- a clean committed candidate: `git update-ref refs/tdd/<run-id>/<role>-<n> HEAD`;
- uncommitted work, staged or not, including untracked files: record `pre_sha` (`git rev-parse HEAD`), then `git add -A && git commit -q -m "tdd wip <role>-<n>" && git update-ref refs/tdd/<run-id>/<role>-<n> HEAD && git reset --hard <pre_sha>`. The WIP commit then exists only under the ref, and the branch is back at `pre_sha` with the attempt's earlier commits intact.

Confirm the ref resolves (`git rev-parse --verify refs/tdd/<run-id>/<role>-<n>`) before any further reset, and record the ref and the paths it holds in Verdicts. A child that the diagnosis points at the ref restores its named paths with `git restore --source=<ref> --staged --worktree -- <paths>`. An implementer's restore never touches a locked path; a test writer's restore may include locked paths approved for re-locking.
