---
name: tdd
description: Implement one ticket through delegated children, with an oracle gate before testing. Use for a feature, a bug fix, or a review fix handed off by another skill.
---

# Test-driven development

You are the **orchestrator** of one ticket. You decide what is tested, start one child per phase, and verify each result. Children write every test and every line of production code. You write only the run directory, the lock record, the reset or restore after a rejection, the [replay](calibration.md#replay) of a saved mutation patch, and a [mechanical correction](#mechanical-corrections) of a locked test.

## Invariants

- **Lock before code.** When tests are required, they are accepted and locked before any implementer starts, and `git diff --exit-code <lock_sha> -- <locked paths>` is the only enforcement. An implementer that changes a locked path is rejected, except through a recorded [mechanical correction](#mechanical-corrections).
- **Evidence, not claims.** You accept a result on [valid evidence](#evidence), never on a report's verdict.

## Evidence

**Valid evidence** is what the Evidence [child rule](run-directory.md#child-rules) defines.

A report is an index to the evidence, not the evidence: a missing field, path, or table is read from the run directory and the checkout, and a doubt is settled by the log. Evidence that is nowhere to be found is work that did not happen ([recovery.md](recovery.md), Handoff). Reuse evidence across roles under `~/.claude/shared/testing.md`, Select checks before execution, and record its source in Verdicts. Each implementation turn runs the named test command on its final state, and later roles reuse that result. A log of a deleted temporary control stays valid when it identifies the control code it ran.

### Identifiers

Every SHA you record, `base_sha`, `batch_start_sha`, `lock_sha`, a Verdicts tip, is `git rev-parse` output from the checkout, never a value copied from a report. A commit, range, or repository a child records follows the Identifiers [child rule](run-directory.md#child-rules); verify it with that rule's commands.

## Before the chain

- Record the checkout (`git rev-parse --show-toplevel`) and the branch: the ticket branch the caller gave, or the current branch.
- The worktree must be clean (`git status --porcelain` is empty). When it is not, report the dirty paths to the caller and stop.
- Use the caller's run directory, or create `~/.claude/artifacts/tdd-<YYYYMMDD-HHMMSS>/<ticket>/`, where `<ticket>` is the issue number or a short slug. Its files, their layouts, and the atomic-write rule are in [`run-directory.md`](run-directory.md).
- Write `ticket.md` with the ticket text, verbatim, and its validation criteria. The ticket is the issue the caller named, or the caller's request when there is none. When the ticket states no criteria, write them from its text. Each criterion carries its **evidence**, an **occurrence**: the ticket sentence it restates, or a report, log, transcript line, corpus entry, or incident that says where and when the behavior happened; a reproduction counts when it reproduces one of these. An input that a reviewer, a ticket author, or you built to show that a path *could* fail is a **construction**, however faithfully it runs. A construction, like any scenario, limit, guard, or path without an occurrence, is a question for the caller when it would decide the fix, and otherwise stays out of `ticket.md`.
- A test enters the chain only through a criterion in `ticket.md`, and a criterion only with its occurrence. This holds for a criterion you add later as much as for the first list: a ticket sentence you missed is an occurrence, and so is the caller's answer to a **Decision**, recorded in Verdicts with its date. A defect you find yourself while inspecting a candidate is a diagnosis ([recovery.md](recovery.md)), never a criterion.
- Copy only the ticket's explicit non-goals into `ticket.md`; an unnamed neighbor may be a necessary consequence of the change. Ask the caller only when an assumed non-goal would exclude a plausible solution or decide a product contract.
- When the ticket reports a bug (the `bug` label, or its text describes current behavior as wrong), add the `Symptom` section from [`symptom.md`](symptom.md) to `ticket.md`.

Done when the worktree is clean and `ticket.md` holds the ticket, its criteria with their evidence, explicit non-goals, and its symptom when it reports a bug.

## The chain

1. **Oracle gate.** For each criterion, decide whether a permanent test is warranted. Apply the repository's test-oracle gate when its instructions name one, and the oracle rule in `~/.claude/shared/testing.md`. Each criterion gets one verdict, and both are complete paths:
   - **test**: its oracle line, in the `Oracle gate` layout of `ticket.md`.
   - **no test**: the reason. The usual cases are agent-facing text, a verbatim copy or move, and config with no observable behavior.

   A symptom criterion marked **no test**, here or later in step 3, takes the [observation gate](symptom.md#observation-gate) before step 4.

   Done when every criterion in `ticket.md` carries a verdict. When none is marked **test** and no `lock.json` exists, this is the **checks-only path**: skip step 3. An existing lock and its test command stay in force.
2. **Seams and checks.** Record in `ticket.md`, reusing fields an earlier batch recorded when they are unchanged:
   - for every **test** criterion: the public boundary, the allowed test paths and fixtures, and the test command: the repository's own runner, or the stack's built-in runner when the repository has none. Installing a runner is a new dependency and a **Decision** for the caller ([recovery.md](recovery.md#responding-to-a-failure));
   - the applicable checks from the repository's verification rules; ask the caller when it names none;
   - both roles' starting tiers and reasons (Starting tiers, below);
   - the ticket's size and its reason (Size, below);
   - each assertion named as a false-green risk, when any ([Calibration](#calibration));
   - the batch number, its `batch_start_sha`, and its turn count and limit ([batches](#batches-and-turns)).

   Starting tiers: the test writer starts on `medium`, or `high` when any test criterion drives a browser or renders UI (e2e, component, visual). The implementer starts on `low` when the production change touches one file, otherwise on `low+`; count only production files and record the reason in `ticket.md`. A later batch applies the same count to its own production files, with its reason recorded on the dispatch's Verdicts line. Tiers map to model and effort through `~/.claude/shared/model-tiers.md`.

   Size: a ticket is **small** when at most two criteria are marked **test**, the production change is expected in at most three files, and the interface is settled: the change adds no glossary term or ADR and needs no `codebase-design` load. Every other ticket is **full**. A small ticket takes the **light path**: the same two children, and the lock in step 3 accepted on **Scope**, **Results**, **Oracle**, and **Reconciliation** alone. Record `small` or `full` with the test-criteria count, the expected production-file count, and whether the interface is settled as its reason.

   Read the area's glossary and ADRs when present. For an unsettled interface, load `codebase-design`. Done when these fields are recorded for the batch.
3. **Test writer.** Record `base_sha` (`git rev-parse HEAD`) and start a test writer in **prepare** mode ([Dispatch](#dispatch), brief: `test-writer.md` in this skill's directory). When it settles, inspect the worktree, the report, and the evidence before changing repository state. Accept the lock only when all of these hold (on the light path, the four conditions Size names):
   - **Scope:** `git diff --name-only <base_sha> HEAD` lists only allowed test paths and fixtures, and the worktree is clean.
   - **Results:** each new test is red on its behavior assertion, or is a negative or aggregate case green on the lock state; such a case is a false-green risk by its form: give it a row ([Calibration](#calibration)) or report it to the caller as uncalibrated. On a first lock or behavior gap, the test command must include red for missing behavior, and for a symptom criterion that red shows the symptom; red for another reason rejects the attempt. Setup, import, and syntax failures reject the attempt. Corrected tests on a re-lock may already be green.
   - **Oracle:** each test matches its report's oracle line, and the line holds against the oracle gate and the false-green rules in `~/.claude/shared/testing.md`.
   - **Controls:** each control the brief requires exists and its result matches the independent expectation. For unavailable live dependencies, follow the repository's verification rules and record the exact unverified boundary.
   - **Shape:** each new fixture and test case follows the variant rule in step 2 of the test writer brief.
   - **Static checks:** each check in `ticket.md` whose coverage includes a changed test path has [valid passing evidence](#evidence) on the candidate.
   - **Plan:** each assertion `ticket.md` names as a false-green risk has a complete Calibration row ([layout](run-directory.md#ticketmd)).
   - **Reconciliation:** every criterion is reconciled with the report: each zero-test criterion has either an accepted **no test** reason or a diagnosis that blocks it. A mixed result stays pending until every disposition and required observation is recorded.

   An accepted zero-test reason moves its criterion to **no test**; lock the remaining test changes only after reconciliation. On acceptance, write the lock: the branch tip becomes `lock_sha`, and the changed files become the locked paths. A failed condition takes [recovery.md](recovery.md): diagnosis, preservation, then the route; a rejection resets the branch (`git reset --hard <base_sha>`, then `git clean -fd`). Done when the work is locked, or the ticket is on the checks-only path.
4. **Implementer.** Start an implementer (brief: `implementer.md`). It writes code until the locked tests pass and the criteria hold. Done when the child has settled; work its brief requires that did not happen is a handoff gap.
5. **Validation.** All of these must hold for the same state:
   - the lock diff exits 0 after `lock_sha` has moved past every recorded [mechanical correction](#mechanical-corrections) (skip on the checks-only path);
   - the test command has valid green evidence (skip when `ticket.md` names none);
   - each planned [calibration](#calibration) holds a **calibrated** verdict whose evidence is still valid under Verdicts in [calibration.md](calibration.md);
   - every applicable check in `ticket.md` has valid passing evidence;
   - every finding of the batch is [closed or reported](#batches-and-turns);
   - **Scope:** inspect the cumulative diff from the batch's `batch_start_sha`, not `lock_sha`. Reject a changed file with no criterion, a hunk not needed for its named criterion, or a change inside `Non-goals`. A hunk of the implementer's refactor commit serves the criterion whose change it simplifies; reject it when it breaks a bound of Refactor on green in its brief;
   - **Identifiers:** the [identifiers rule](#identifiers) holds for every record in the batch's diff;
   - the worktree is clean, and the branch tip has moved past `lock_sha`, or past `batch_start_sha` on the checks-only path. A test-only correction needs only its accepted test commit.

   Check the lock and clean state first, then the test command, then pending calibration, then the broader checks that lack valid evidence. A failed condition takes [recovery.md](recovery.md) before any change. Done when all conditions hold.

Report to the caller: `lock_sha` or the checks-only verdict, the final branch tip, each check and calibration verdict with its result, any named uncalibrated boundary, each open question with its diagnosis, the batch's turn count, and the run directory.

### Entering mid-chain

A caller with review findings for a ticket that already ran the chain opens a new [batch](#batches-and-turns), re-checks `Non-goals` against its new criteria in steps 1-2, and enters at a later step. A review batch takes the light path. These routes are for the caller's findings; your own diagnosis takes [recovery.md](recovery.md). A review-fix criterion that conflicts with a recorded non-goal is a **Decision** ([recovery.md](recovery.md#responding-to-a-failure)):

- A **behavior gap** (the code is wrong and no test catches it): add the criterion with the finding as its occurrence and its verdict, record its symptom, run step 3 to extend the lock, then steps 4 and 5.
- A **code-only finding**: add it to the criteria, then run steps 4 and 5 against the existing lock, or checks-only when there is none.
- A **suspect test** (wrong oracle, false green, or contradictory fixture): record the counterexample, run step 3 to re-lock, then step 4 for every open finding that still needs production work, including code-only findings and any defect the corrected tests expose. Then step 5.

### Batches and turns

A **batch** is the caller's initial ticket or one caller-supplied set of review findings. Internal retries, resumed children, calibration, and re-locks keep the current batch's number and count. Only a new caller-supplied set opens another batch.

A **finding** is a caller-supplied review finding or a diagnosis you recorded. A finding is **open** until its acceptance evidence is recorded in Verdicts. A finding is **closed** by the route its diagnosis takes; a finding whose route is **Decision** is **reported**: it stays in Verdicts as an open question and does not block step 5. When several are open, repair prerequisites first, then suspect tests, then run one implementer for all open production work.

Every dispatched or resumed child is one **turn** of its batch. Before each dispatch, compare the batch's turn count with its limit, recorded in `ticket.md` with a default of 8. Two turns before the limit, the batch enters **finish mode**: the remaining turns go only to the implementer, for failing locked tests and red checks. Open no criterion, re-lock, or calibration; drop a planned calibration that has not run, and record every other open finding as reported with its diagnosis, so it does not block step 5. At the limit, accept a completed success; otherwise end the batch blocked and report the remaining work and the diagnosis to the caller. Only the caller changes the limit.

## Mechanical corrections

A defect in a locked test is **mechanical** when the correct value is already in the checkout or the ticket, untouched by this ticket's change, and nothing else in the test changes: a literal that must equal unchanged product copy or an existing label, a locator that must name an existing element, a fixture flag the scenario needs to be live, a path or import that moved. The oracle line in `ticket.md` is unchanged and still holds for the corrected test; the `M<n>` line cites it and the source of the value, which meets the gate in `~/.claude/shared/testing.md` (Editing a test is authoring it).

Whoever finds it corrects it: the implementer during its turn, you while inspecting a candidate or validating. The correction is one commit that touches only that test path, recorded as an `M<n>` line ([layout](run-directory.md#ticketmd)). An implementer's correction is accepted when `git diff <lock_sha> <its commit> -- <locked paths>` shows only the recorded change. On acceptance, or on your own correction, `lock_sha` moves to that commit; the locked paths stay.

A defect whose correct value needs a choice, such as which behavior the ticket means, which oracle holds, or whether the contract changed, is a diagnosis and takes [recovery.md](recovery.md).

## Calibration

Calibration is opt-in. An assertion is calibrated only when you name it in `ticket.md` as a **false-green risk**: an assertion with a false-green form from `~/.claude/shared/testing.md` that you can state, such as a negative assertion that also passes when the element never renders, or an aggregate that also passes with the wrong members. Name them at step 2, and add any the preparation report shows, each with its form. Validity of calibrated evidence: Verdicts in [calibration.md](calibration.md). Read it before the calibrate child starts, when a review finds a masking helper or fixture, or when a locked path changed after calibration.

## Responding to a failure

A failed or incomplete settlement gets its diagnosis before any reset, restore, or dispatch: read [recovery.md](recovery.md) first.

## Dispatch

Before starting or resuming a child, read [`dispatch.md`](dispatch.md): the prompt template, the launch modes, resuming, and reaping.
