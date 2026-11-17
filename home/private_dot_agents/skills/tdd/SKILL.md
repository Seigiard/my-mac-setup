---
name: tdd
description: Implement one ticket through locked tests and delegated children. Use for a feature, a bug fix, or a review fix handed off by another skill.
---

# Test-driven development

You are the **orchestrator** of one ticket. You decide what is tested, start one child per phase, and accept each result on evidence. Children write every test and every line of production code. The test writer's tests are locked before the implementer starts, so the implementer cannot pass them by changing them.

**Evidence, not claims.** A result is accepted on the command, its exit status, the commit it ran on, and the output that shows the scenario ran. A report is an index to that evidence, not the evidence: a missing field is read from the run directory and the checkout, and a doubt is settled by the log. Every SHA you record is `git rev-parse` output from the checkout.

## Before the chain

- Record the checkout and the branch: the ticket branch the caller gave, or the current branch. The worktree must be clean (`git status --porcelain` is empty); otherwise report the dirty paths to the caller and stop.
- Use the caller's run directory, or create `~/.claude/artifacts/tdd-<YYYYMMDD-HHMMSS>/<ticket>/`. Its files and the `ticket.md` layout are in [`run-directory.md`](run-directory.md).
- Write `ticket.md`: the ticket text verbatim and its **criteria**, each with its **occurrence**: the ticket sentence it restates, or the report, log, transcript line, or incident that says where the behavior happened. A scenario, limit, or guard that someone built to show a path *could* fail is a **construction**: a question for a person when it would decide the fix, otherwise out of `ticket.md`. A test enters the chain only through a criterion. Copy the ticket's explicit non-goals; an unnamed neighbor may be a necessary consequence of the change.
- When the ticket reports a bug, add its `Symptom`: the observed behavior, the expected behavior, and the command or scenario that shows it.

Done when the worktree is clean and `ticket.md` holds the ticket, its criteria with occurrences, its non-goals, and its `Symptom` when the ticket reports a bug.

## The chain

1. **Oracle gate.** For each criterion, decide whether a permanent test is warranted: the oracle rule in `~/.claude/shared/testing.md`, and the repository's test-oracle gate when its instructions name one. Each criterion gets one verdict in `ticket.md`: **test**, with its oracle line (consumer, observable failure, independent oracle), or **no test**, with the reason. The usual **no test** cases are agent-facing text, a verbatim copy or move, and config with no observable behavior. When no criterion is marked **test** and no lock exists, this is the **checks-only path**: skip step 3.
   Done when every criterion carries a verdict.
2. **Seams, checks, tiers, batch.** Record in `ticket.md`, reusing what an earlier batch recorded when unchanged: for each **test** criterion the public boundary and the allowed test paths and fixtures; the test command when a criterion is marked **test**, the repository's own runner or the stack's built-in one (installing a runner is a new dependency and a **decision**), otherwise `Tests: not applicable` with the oracle-gate reason; the checks the repository's verification rules name; each assertion you name as a **false-green risk** ([calibration](#calibration)); both tiers; and the `Batch` line with its number, start SHA, and turn count against the limit of 8. The test writer starts on `medium`, or `high` when a test drives a browser or renders UI; the implementer starts on `low`. Tiers map to models through `~/.claude/shared/model-tiers.md`. Read the area's glossary and ADRs when present; for an unsettled interface, load `codebase-design`.
   Done when these fields are recorded for the batch.
3. **Test writer.** Start a test writer in **prepare** mode ([Dispatch](#dispatch), brief: `test-writer.md`), recording `base_sha` (`git rev-parse HEAD`) on its Verdicts dispatch line. When it settles, read the diff and the report before changing repository state. Accept the **lock** when all of these hold:
   - **Scope:** `git diff --name-only <base_sha> HEAD` lists only the allowed test paths and fixtures, and the worktree is clean.
   - **Red:** each new test is red on its behavior assertion, and the red output shows the missing behavior, or the reported symptom for a bug. Red for a setup, import, or syntax reason rejects the attempt. On a re-lock, corrected tests may already be green.
   - **Oracle:** each test matches its oracle line, and the line holds against `~/.claude/shared/testing.md`.
   - **Reconciliation:** each test names the **test** criterion it serves, and every **test** criterion has one, or an accepted reason that moves it to **no test**.

   On acceptance write `lock.json`: `base_sha`, the branch tip as `lock_sha`, the changed files as the locked `paths`. A failed condition takes [When a child fails](#when-a-child-fails).
   Done when the work is locked, or the ticket is on the checks-only path.
4. **Implementer.** Start an implementer (brief: `implementer.md`).
   Done when the child has settled.
5. **Validation.** All of these hold for the same state:
   - the locked paths are byte-identical to `lock_sha` (`git diff --exit-code <lock_sha> -- <paths>`), or differ only by a [correction](#correcting-a-locked-test) you recorded;
   - the test command, when `ticket.md` names one, and every applicable check have green evidence on the branch tip;
   - **Scope:** read the whole diff from the batch's start SHA. Every changed hunk serves a named criterion or simplifies one in the refactor commit; a hunk that serves no criterion, changes a non-goal, or weakens a test outside the lock is rejected. Weakening also hides in production: a code path that detects test doubles, a shim or flag that exists only to keep a test green, is a rejected hunk;
   - each named false-green risk has a **calibrated** verdict;
   - the worktree is clean.

   Check the lock first, then the test command, then the diff, then calibration, then the broader checks. A failed condition takes [When a child fails](#when-a-child-fails).
   Done when all conditions hold.

Report to the caller: `lock_sha` or the checks-only verdict, the final branch tip, each check and calibration verdict, each open question, the turn count, the run directory, and the **Risks** section ([run-directory.md](run-directory.md#risks)) merged from both children's reports.

### Entering mid-chain

A caller with review findings for a ticket that already ran the chain opens a new **batch**: re-check the non-goals against its findings, run steps 1-2 for them, then enter at a later step:

- A **behavior gap** (the code is wrong and no test catches it): add the criterion with the occurrence the finding names; a finding with no occurrence is a construction and a **decision**. Run step 3 to extend the lock, then steps 4 and 5.
- A **code-only finding**: add it to the criteria, then run steps 4 and 5 against the existing lock, or checks-only when there is none.
- A **suspect test** (false green, wrong oracle, contradictory fixture): record the counterexample, run step 3 to re-lock, then steps 4 and 5 for every open finding.

When several findings are open, re-lock suspect tests first, then run one implementer for all open production work.

## Calibration

A test proves its worth by going red when the behavior breaks. A **false-green risk** is an assertion that could stay green while the behavior is wrong: a negative assertion that also passes when nothing renders, an aggregate that passes with the wrong members, a pair of independent arrays where order is the contract. One row and one mutation per protected assertion; the rows are frozen for the batch, and a row is added only for an assertion a new criterion brings. For each row, the test writer in **calibrate** mode returns **calibrated**, **suspect test**, or **blocked** (`test-writer.md`, Calibrate). A **suspect test** re-locks through step 3. **Blocked** is diagnosed before any other dispatch, since a faithful mutation can expose a production defect. Calibrate after step 5's test command is green, and again only for rows whose owner test changed since.

## Correcting a locked test

A locked test is wrong in a **mechanical** way when the correct value is already in the checkout or the ticket, untouched by this ticket's change: a literal that must equal existing product copy, a locator for an existing element, a path or import that moved. Correct it yourself in one commit touching only that test file, with the oracle line unchanged, record it in Verdicts, and move `lock_sha` to that commit. A defect whose correct value needs a choice, which behavior the ticket means or whether the contract changed, re-locks through a test writer, or is a **decision** for the caller when the ticket does not settle it.

## When a child fails

Before any new dispatch, record a **diagnosis** `D<n>` in Verdicts: the artifact, the failing assertion or condition, the reproduction, and the expected result with its source. Keep a rejected candidate reachable under `refs/tdd/<run-id>/<role>-<n>`; a rejected test writer's branch then returns to `base_sha` (`git reset --hard <base_sha> && git clean -fd`), a rejected implementer's stays at its tip. Then take the smallest of these routes:

- **Resume** the same child when work its brief requires did not happen and the inspected work looks sound (a check never ran, a report field is missing). Once per attempt.
- **Targeted fix** on the same tier when the defect is localized and the correct result is known: a test writer for a test defect, an implementer for a production defect. The prompt names the diagnosis and the paths it may change.
- **One tier up** when the child could not establish, exercise, or implement a behavior whose expected result is settled. On `high+` there is no next tier: report the diagnosis to the caller as remaining work.
- **Decision** to the caller when the available authority does not settle the expected result, the fix needs a behavior the criteria do not name, or a necessary change violates a non-goal. Report the question with its diagnosis; a person's answer adds a criterion and opens a new batch. A calling skill forwards the question and does not answer it.

At the batch's turn limit the batch ends **blocked**: report the remaining work. Only a person raises the limit.

## Dispatch

Before starting or resuming a child, read [`dispatch.md`](dispatch.md): the prompt template, the launch modes, resuming, and turn counting.
