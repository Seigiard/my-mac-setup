---
name: tdd
description: Implement one ticket through delegated children, with an oracle gate before testing. Use for a feature, a bug fix, or a review fix handed off by another skill.
---

# Test-driven development

You are the **orchestrator** of one ticket. You decide what is tested, start one child per phase, and verify each result. Children write every test and every line of production code. You write only the run directory, the lock record, and the reset or restore after a rejection.

## Invariants

- **Lock before code.** When tests are required, they are accepted and locked before any implementer starts, and `git diff --exit-code <lock_sha> -- <locked paths>` is the only enforcement. An implementer that changes a locked path is rejected.
- **Children write; you verify.** You never write a test, a fix, or a merge yourself. When no child can start, stop and report.
- **Evidence, not claims.** You accept a result on [valid evidence](#evidence), never on a report's verdict.
- **Clean boundaries.** The worktree is clean at every phase boundary, so each diff belongs to one child.
- **Identifiers from git.** Every SHA you record, `base_sha`, `batch_start_sha`, `lock_sha`, a Verdicts tip, is `git rev-parse` output from the checkout, never a value copied from a report.
- **Classify before recovery.** A failed or incomplete settlement gets its diagnosis under [Responding to a failure](#responding-to-a-failure) before any reset, restore, or dispatch; a successful one gets an acceptance verdict.

## Evidence

**Valid evidence** for a check or control is the command, its exit status, the code state it ran on, and the output that shows the required scenarios ran. A pass/fail summary alone is not evidence. A skipped or focused run is not evidence for a required broader suite.

Evidence stays valid while the covered code, tests, fixtures, generated state, and environment are unchanged. Reuse it across roles and record its source in Verdicts. Repeat a check only when its covered state changed or a concrete contradiction questions it. One exception: each implementation turn runs the named test command on its final state, and later roles reuse that result. A child's tool output and saved logs supply evidence. A log of a deleted temporary control stays valid when it identifies the control code it ran; a command that now finds no tests is a handoff gap, not a counterexample.

## Before the chain

- Record the checkout (`git rev-parse --show-toplevel`) and the branch: the ticket branch the caller gave, or the current branch.
- The worktree must be clean (`git status --porcelain` is empty). When it is not, report the dirty paths to the caller and stop.
- Use the caller's run directory, or create `~/.claude/artifacts/tdd-<YYYYMMDD-HHMMSS>/<ticket>/`, where `<ticket>` is the issue number or a short slug. Its files, their layouts, and the atomic-write rule are in [`run-directory.md`](run-directory.md).
- Write `ticket.md` with the ticket text, verbatim, and its validation criteria. The ticket is the issue the caller named, or the caller's request when there is none. When the ticket states no criteria, write them from its text.
- Copy only the ticket's explicit non-goals into `ticket.md`; an unnamed neighbor may be a necessary consequence of the change. Ask the caller only when an assumed non-goal would exclude a plausible solution or decide a product contract.
- When the ticket reports a bug (the `bug` label, or its text describes current behavior as wrong), add a `Symptom` section to `ticket.md`: the observed behavior with the command or scenario the ticket gives, the expected behavior, and the criterion that covers it.

Done when the worktree is clean and `ticket.md` holds the ticket, its criteria, explicit non-goals, and its symptom when it reports a bug.

## The chain

1. **Oracle gate.** For each criterion, decide whether a permanent test is warranted. Apply the repository's test-oracle gate when it has one (in my-mac-setup: `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`) and the oracle rule in `~/.claude/shared/testing.md`. Each criterion gets one verdict, and both are complete paths:
   - **test**: the consumer, the observable failure, and the independent oracle, on one line.
   - **no test**: the reason. The usual cases are agent-facing text, a verbatim copy or move, config with no observable behavior, and behavior owned by an upstream system.

    **Observation gate.** A symptom criterion marked **no test**, at this gate or later in step 3, needs a recorded observation before step 4: the command or scenario from `Symptom`, run on the production base, with its state and output recorded under `Symptom`. This applies per criterion, including in a ticket whose other criteria have locked tests. When the observation shows the reported symptom, continue. When it reaches the expected behavior under the recorded preconditions, the bug is [not reproduced](#responding-to-a-failure). Otherwise classify the incomplete observation under [Responding to a failure](#responding-to-a-failure) before any implementation: an unrunnable command is **Prerequisite**, a missing scenario or expected result is **Decision**.

   Done when every criterion in `ticket.md` carries a verdict. When none is marked **test** and no `lock.json` exists, this is the **checks-only path**: skip step 3. An existing lock and its test command stay in force.
2. **Seams and checks.** Record in `ticket.md`, reusing fields an earlier batch recorded when they are unchanged:
   - for every **test** criterion: the public boundary, the allowed test paths and fixtures, and the test command;
   - the applicable checks from the repository's verification rules (in my-mac-setup: `docs/agent-verification.md`; ask the caller when the repository has none);
   - both roles' starting tiers and reasons (Starting tiers, below);
   - the batch number, its immutable `batch_start_sha` (`HEAD` when the batch opens and preserved across retries and re-locks), and its turn count and limit ([batches](#batches-and-turns)).

   Starting tiers: the test writer starts on `medium`, or `high` when any test criterion drives a browser or renders UI (e2e, component, visual). The implementer starts on `low` when the production change touches one file, otherwise on `low+`; count only production files and record the reason in `ticket.md`. A later batch applies the same count to its own production files, so a batch that touches one file starts on `low` under a `low+` ticket, with its reason recorded on the dispatch's Verdicts line. A Capability diagnosis climbs one rung. On `high+`, there is no next tier: stop. Tiers map to model and effort through `~/.claude/shared/model-tiers.md`.

   Read the area's glossary and ADRs when present. For an unsettled interface, load `codebase-design`; ask the user when it needs a product decision. Done when these fields are recorded for the batch.
3. **Test writer.** Record `base_sha` (`git rev-parse HEAD`) and start a test writer in **prepare** mode ([Dispatch](#dispatch), brief: `test-writer.md` in this skill's directory). When it settles, inspect the worktree, the report, and the evidence before changing repository state. A [handoff gap](#responding-to-a-failure) keeps the candidate in place and resumes the child. Otherwise accept the lock only when all of these hold:
   - **Scope:** `git diff --name-only <base_sha> HEAD` lists only allowed test paths and fixtures, and the worktree is clean.
   - **Results:** each new test is red on its behavior assertion, or is a negative or aggregate case with an [uncalibrated assertion](#calibration). On a first lock or behavior gap, the test command must include red for missing behavior, and for a symptom criterion that red shows the symptom; red for another reason rejects the attempt. Setup, import, and syntax failures reject the attempt. Corrected tests on a re-lock may already be green.
   - **Oracle:** each test matches its report's oracle line, and the line holds against the oracle gate and the false-green rules in `~/.claude/shared/testing.md`.
   - **Controls:** every control in the report's table has valid evidence, and its observed result matches the independent expected result. The helpers and fixtures the brief requires are covered. For unavailable live dependencies, follow the repository's verification rules and record the exact unverified boundary.
   - **Static checks:** each check in `ticket.md` whose coverage includes a changed test path, the repository's lint and typecheck gates among them, has [valid passing evidence](#evidence) on the candidate.
   - **Plan:** each uncalibrated negative or aggregate assertion has an owner test and a finite regression plan in `ticket.md`.
    - **Reconciliation:** every criterion is reconciled with the report: each zero-test criterion has either an accepted **no test** reason or a diagnosis that blocks it. A mixed result stays pending until every disposition and required observation is recorded.

   After reconciliation, a report with no tests, a reason for every criterion, and no movement from `base_sha` moves those criteria to **no test**. For a mixed result, an accepted zero-test reason moves that criterion to **no test**, so step 1's observation gate applies before acceptance; lock the remaining test changes only after reconciliation. A symptom criterion whose faithful test reached its assertion and passed is [not reproduced](#responding-to-a-failure). On acceptance, write the lock: the branch tip becomes `lock_sha`, and the changed files become the locked paths. On rejection, record the diagnosis, [preserve the candidate](#preserving-a-candidate), then reset the branch (`git reset --hard <base_sha>`, then `git clean -fd`) and take the diagnosis's route. Done when the work is locked, or the ticket is on the checks-only path.
4. **Implementer.** Start an implementer (brief: `implementer.md`). It writes code until the locked tests pass and the criteria hold. Done when the child has settled and its report names its commit, the changed paths, the evidence for the test command and each check, and anything left undone.
5. **Validation.** All of these must hold for the same state:
   - the lock diff exits 0 (skip on the checks-only path);
   - the test command has valid green evidence (skip when `ticket.md` names none);
   - each planned [calibration](#calibration) is **calibrated** for the current protected code, tests, and fixtures;
   - every applicable check in `ticket.md` has valid passing evidence;
   - every finding of the batch is closed: its acceptance evidence is recorded in Verdicts;
   - **Scope:** inspect the cumulative diff from the batch's `batch_start_sha`, not `lock_sha`. Reject a changed file with no criterion, a hunk not needed for its named criterion, or a change inside `Non-goals`;
   - **Identifiers:** every commit or range a tracked file in the batch's diff records resolves in the repository the record names, or this checkout when it names none (`git rev-parse --verify <sha>^{commit}`; `git merge-base --is-ancestor <base> <head>` exits 0); a record marked unresolved is exempt;
   - the worktree is clean, and the branch tip has moved past `lock_sha`, or past `batch_start_sha` on the checks-only path. A test-only correction needs only its accepted test commit.

   Check the lock and clean state first, then the test command, then pending calibration, then the broader checks that lack valid evidence. A failed condition gets a diagnosis before any change: a handoff gap resumes the child; an implementation defect [preserves any uncommitted work](#preserving-a-candidate), restores any changed locked files (`git restore --source=<lock_sha> --staged --worktree -- <locked paths>`, commit only when that creates a diff), keeps the attempt's other commits on the branch, and takes the diagnosis's route. Done when all conditions hold.

Report to the caller: `lock_sha` or the checks-only verdict, the final branch tip, each check and calibration verdict with its result, any named uncalibrated boundary, the batch's turn count, and the run directory.

### Entering mid-chain

A caller with review findings for a ticket that already ran the chain opens a new [batch](#batches-and-turns), re-checks `Non-goals` against its new criteria in steps 1-2, and enters at a later step. A review-fix criterion that conflicts with a recorded non-goal is a **Decision** for the caller, not a silent override or block:

- A **behavior gap** (the code is wrong and no test catches it): add the criterion and its verdict, record its symptom, run step 3 to extend the lock, then steps 4 and 5.
- A **code-only finding**: add it to the criteria, then run steps 4 and 5 against the existing lock, or checks-only when there is none.
- A **suspect test** (wrong oracle, false green, or contradictory fixture): record the counterexample, run step 3 to re-lock, then step 4 for every open finding that still needs production work, including code-only findings and any defect the corrected tests expose. Skip step 4 only when no such finding remains. Then step 5.

### Batches and turns

A **batch** is the caller's initial ticket or one caller-supplied set of review findings. Internal retries, resumed children, calibration, and re-locks keep the current batch's number and count. Only a new caller-supplied set opens another batch.

Each finding of a batch is **open** until its acceptance evidence is recorded in Verdicts. When several are open, repair prerequisites first, then suspect tests, then run one implementer for all open production work.

Every dispatched or resumed child is one **turn** of its batch. Before each dispatch, compare the batch's turn count with its limit, recorded in `ticket.md` with a default of 8. At the limit, accept a completed success; otherwise report the remaining work and the diagnosis to the caller and wait. Only the caller changes the limit.

## Calibration

Before assessing a lock with uncalibrated negative or aggregate assertions or a review that finds a masking helper or fixture, read [calibration.md](calibration.md).

## Responding to a failure

Before recovering from any failed or incomplete settlement, read [recovery.md](recovery.md).

### Preserving a candidate

Before any reset, restore, or `git clean`, follow [Preserving a candidate](recovery.md#preserving-a-candidate).

## Dispatch

Every child runs on OpenCode with an `openai/*` model from the OpenCode column of `~/.claude/shared/model-tiers.md`.

Write the child's prompt to `<role>-<n>.prompt.md`. It carries pointers only, never pasted history:

```text
Role: <test writer | implementer>, attempt <n>.
Mode: <prepare | calibrate>   <- test writer only
Read your brief first and follow it: <absolute path to test-writer.md or implementer.md>.
Ticket: <run-dir>/ticket.md (its Verdicts section lists earlier attempts and why they were rejected).
Lock: <run-dir>/lock.json   <- when a lock exists: implementer, or a test writer that re-locks or extends it
Targeted fix: <diagnosis ID in Verdicts>   <- targeted fix only
Exclusive file scope: <allowed test paths and fixtures | planned temporary production paths | the whole checkout>   <- prepare | calibrate | implementer
Report: <run-dir>/<role>-<n>.report.md; publish it by the atomic-write rule in <absolute path to run-directory.md>.
Work in <checkout> on branch <branch>. Commit prepare and implementation work. Calibration restores <calibration_sha> without commits. Do not push.
```

Choose the launch mode in this order:

1. `HERDR_ENV=1` and `HERDR_CHILD_PARENT_PANE` is unset: start a visible tab with `herdr-child start --kind opencode --posture rw --model <model> --effort <effort of tier> --cwd <checkout> --prompt-file <prompt> --detach`. Tabs avoid the narrow-pane OpenCode hang. Follow the parent duties in `~/.claude/shared/child-agent-contract.md`; the supervision marker wakes you. Answer a child's `herdr-child ask` from `ticket.md`; pass it to the user only when it needs a product decision. A herdr child goes straight to mode 2 because `herdr-child start` refuses to run from a child pane.
2. `opencode` is on `PATH`: run the following as a background process that re-invokes you on exit (in Claude Code, the Bash tool's `run_in_background`). The stdin redirect prevents `opencode run` from waiting for EOF. `~/.claude/shared/long-running-work.md` owns its supervision.

   ```bash
   (
     cd <checkout> || exit
     exec opencode run -m <model>#<variant of tier> --standalone --auto --format json "$(cat <prompt>)"
   ) < /dev/null > <run-dir>/<role>-<n>.jsonl 2>&1
   ```

   Keep the process exit status and the JSONL events separate. An `error` event or a log that ends without a final answer is incomplete work; a zero process exit alone is not a task-success verdict.
3. Otherwise no child can start. Stop.

**Resuming a child** for a handoff gap keeps its session, tier, and attempt number, and counts as one turn. In herdr mode: `herdr-child prompt --to <name> --pane <pane-id> --detach '<the missing items>'`. In headless mode: the same subshell command with `--session <id>` added and `'<the missing items>'` as the prompt, appending to `<run-dir>/<role>-<n>-resume.jsonl`, where the id is the `sessionID` in the attempt's JSONL log. Every resumed turn of the attempt appends to that file in order.

The child's answer is its report file; its tool output and logs are the evidence the report cites. In herdr mode, reap each child with `herdr-child reap` in the turn that records its accepted result or final diagnosis, following the lifecycle rule of the `herdr` skill. In headless mode, confirm the process has exited before the next phase starts.
