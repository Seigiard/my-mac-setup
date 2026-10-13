# Failure recovery

The tdd orchestrator's diagnosis routes and candidate preservation, reached from [Responding to a failure](SKILL.md#responding-to-a-failure) in SKILL.md.

## Responding to a failure

Every failed or incomplete settlement gets a **diagnosis** in Verdicts before any reset, restore, or dispatch. A diagnosis has an ID (`D1`, `D2`, ...), the artifact it concerns, the affected assertion or boundary, a reproduction, and the independent expected result. One settlement can carry several diagnoses; each takes its own route, in the order [Batches and turns](SKILL.md#batches-and-turns) gives for open findings. Take the **smallest action that fixes exactly the diagnosis**; model escalation is for a child that could not do the work, never for a slip.

The diagnosis records the authoritative source that settles the expected result, or the missing decision, before the route is chosen.

| Artifact and diagnosis | Smallest action |
|---|---|
| **Handoff:** the report, a log, or a control artifact is missing, including a report mapping to an existing criterion, and the inspected work looks sound | Resume the same child ([Dispatch](SKILL.md#dispatch)) naming the missing items; a check that never ran is named as a check to run now. Report-only corrections need no commit. An item still missing after one resume is a returned diagnosis. When the child's session is gone, a fresh child on the same tier gets the [preserved candidate](#preserving-a-candidate) and the remaining work. |
| **Test preparation:** a localized defect with a reproduction and a known correct result (a missing `await`, a helper that echoes its input, one wrong fixture) | A **targeted fix** by a test writer on the same tier: its prompt names the preserved candidate ref, the diagnosis, and the paths it may change. It restores those paths from the ref and changes only what the diagnosis names. Full lock acceptance (step 3 in [The chain](SKILL.md#the-chain)) follows. |
| **Not reproduced:** during the initial investigation of a bug or of a new behavior gap, a test-based verdict meets the applicable **Scope**, **Oracle**, **Controls**, and **Plan** conditions from step 3 in [The chain](SKILL.md#the-chain), with **Results** showing the symptom criterion's faithful test reaching the expected-behavior assertion and passing on `base_sha` instead of showing symptom-red; an observation keeps valid evidence for its scenario and controls. A suspect-test re-lock follows the existing re-lock and calibration rules | Stop. Report the symptom, the test or command that sought it, and the observed behavior. The ticket may be stale, already fixed, or environment-specific; the caller decides. |
| **Production:** a localized defect with a reproduction and a known correct result | A **targeted fix** by an implementer on the same tier, continuing from the current branch tip; its prompt names the diagnosis, the paths it may change, and the control that confirms the fix. Full validation (step 5 in [The chain](SKILL.md#the-chain)) follows. |
| **Production:** a changed file or hunk serves no existing criterion | A **targeted fix** by an implementer on the same tier, using the existing **Production** route above: name the diagnosis and paths it may change, continue from the current branch tip, and follow with full validation. The orchestrator changes no repository file. |
| **Locked test:** a test is wrong (false green, wrong oracle, contradictory fixture) | The suspect-test route under [Entering mid-chain](SKILL.md#entering-mid-chain), on the tier of the last accepted lock. The implementer is never asked to satisfy a wrong test. |
| **Calibration:** a mutation was unfaithful, or restoration failed | Recover and verify the production snapshot at `calibration_sha`, then a fresh calibrate child. The lock stays. |
| **Capability:** an authoritative contract or oracle source already settles the expected result, but the child could not establish the behavior from it, exercise it, or produce a faithful regression | A fresh child one tier up with the diagnosis in its prompt. On `high`, there is no next tier: stop. |
| **Prerequisite:** the environment or the caller's brief is wrong | The orchestrator corrects run-directory data, brief data, and environment state within its scope. A repository edit goes to a scoped child only when an existing criterion already requires the repair; otherwise return the scope decision to the caller as **Decision**. After each repair, retry the same tier. When it cannot be restored with the tools and access you have, stop. |
| **Decision:** the available authority does not settle the expected result, or sources conflict, a change needs a product decision, or a necessary change violates a non-goal | Ask the caller. No model change answers this. |

A diagnosis **returns** when its recorded reproduction still fails after a turn assigned to fix it. A new reproduction is a new diagnosis, which counts against the batch's turns but is not a return.

The chain **stops**, reporting the diagnoses and the run directory, when:

- the worktree is dirty before the chain, or no child can start;
- a diagnosis returns;
- a bug is not reproduced;
- a capability failure happens on `high`, or a prerequisite cannot be restored;
- another dispatch is needed and the batch has no turns left;
- the caller must decide an oracle or a product question.

### Preserving a candidate

Before any reset, restore, or `git clean`, keep what the child produced reachable as one ordinary commit under `refs/tdd/<run-id>/<role>-<n>`:

- a clean committed candidate: `git update-ref refs/tdd/<run-id>/<role>-<n> HEAD`;
- uncommitted work, staged or not, including untracked files: record `pre_sha` (`git rev-parse HEAD`), then `git add -A && git commit -q -m "tdd wip <role>-<n>" && git update-ref refs/tdd/<run-id>/<role>-<n> HEAD && git reset --hard <pre_sha>`. The WIP commit then exists only under the ref, and the branch is back at `pre_sha` with the attempt's earlier commits intact.

Confirm the ref resolves (`git rev-parse --verify refs/tdd/<run-id>/<role>-<n>`) before any further reset, and record the ref and the paths it holds in Verdicts. A child that the diagnosis points at the ref restores its named paths with `git restore --source=<ref> --staged --worktree -- <paths>`. An implementer's restore never touches a locked path; a test writer's restore may include locked paths approved for re-locking.
