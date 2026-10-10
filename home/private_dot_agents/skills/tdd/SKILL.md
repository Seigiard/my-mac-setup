---
name: tdd
description: Implement one ticket test-first through delegated children. Use for a feature, a bug fix, or a review fix handed off by another skill.
---

# Test-driven development

You are the **orchestrator** of one ticket. You decide what is tested, start one fresh child per phase, and verify each result. Children write every test and every line of production code. You write only the run directory, the lock record, and the reset or restore after a rejection.

## Before the chain

- Record the checkout (`git rev-parse --show-toplevel`) and the branch: the ticket branch the caller gave, or the current branch.
- The worktree must be clean (`git status --porcelain` is empty), so every diff belongs to one child. When it is not, report the dirty paths to the caller and stop.
- Use the caller's run directory, or create `~/.claude/artifacts/tdd-<YYYYMMDD-HHMMSS>/<ticket>/`, where `<ticket>` is the issue number or a short slug. It holds:
  - `ticket.md`: the ticket and every decision about it ([layout](#ticketmd)).
  - `lock.json`: the lock record ([layout](#the-lock)).
  - `<role>-<n>.prompt.md` and `<role>-<n>.report.md`: one prompt and one report per child, numbered per role from 1.
- Write every file there atomically: write `<file>.tmp`, then rename it.
- Write `ticket.md` with the ticket text, verbatim, and its validation criteria. The ticket is the issue the caller named, or the caller's request when there is none. When the ticket states no criteria, write them from its text.

Done when the worktree is clean and `ticket.md` holds the ticket and its criteria.

## The chain

1. **Oracle gate.** For each criterion, decide whether a permanent test is warranted. Apply the repository's test-oracle gate when it has one (in my-mac-setup: `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`) and the oracle rule in `~/.claude/shared/testing.md`. Each criterion gets one of two verdicts, and both are complete paths:
   - **test**: the consumer, the observable failure, and the independent oracle, on one line.
   - **no test**: the reason. The usual cases are agent-facing text (skills, instruction docs), a verbatim copy or move, config with no observable behavior, and behavior owned by an upstream system; the two gate documents carry the reasoning.

    Done when every criterion in `ticket.md` carries a verdict. When none is marked **test**, skip step 3. With no `lock.json`, this is the **checks-only path**; otherwise keep the existing lock and its test command for validation.
2. **Seams and checks.** Record these in `ticket.md`:
   - For every **test** criterion: the public boundary, allowed test paths and fixtures, and test command. Read the area's glossary and ADRs when present. For an unsettled interface, load `codebase-design`; ask the user when it needs a product decision.
   - Applicable checks from the repository's verification rules (in my-mac-setup: `docs/agent-verification.md`). When the repository has none, ask the caller.
   - The implementer's [starting tier](#escalation-ladder) and its reason.
   - The current [batch and budgets](#batch-budgets). Open a batch for the caller's initial ticket or new review findings; internal retries use the current batch.
   - On the checks-only path, `base_sha` (`git rev-parse HEAD`). Test preparation records its own baseline in step 3.

   Done when all these fields are recorded for the batch.
3. **Test writer.** Record `base_sha` (`git rev-parse HEAD`) and start a test-writer child in **prepare** mode ([dispatch](#dispatch), brief: `test-writer.md` in this skill's directory). When it settles:
   - **Zero tests.** When the report gives zero tests with a reason for every criterion and the branch has not moved from `base_sha`, move each criterion to **no test** with that reason. Keep any existing lock and its test command; use checks-only only when no lock exists.
   - **Otherwise:** apply every condition in [Accepting the lock](#accepting-the-lock).

   On **rejection**, record the findings and their [classification](#escalation-ladder). Before resetting a clean committed candidate, keep it reachable with `git update-ref refs/tdd/<run-id>/test-writer-<n> <candidate_sha>` and record that ref in Verdicts. Reset the branch (`git reset --hard <base_sha>`, then `git clean -fd`); the existing lock stays unchanged. Route the next attempt through the ladder, including its bounded [narrow repair](#narrow-repair) exception.

   On acceptance, write the [lock](#the-lock): the branch tip becomes `lock_sha`, and the changed files become the locked paths. Record any criterion with zero tests as **no test**, with its reason. Done when the work is locked, or the ticket is on the checks-only path.
4. **Implementer.** Start an implementer child (brief: `implementer.md` in this skill's directory). It writes code until the locked tests pass and the criteria hold. If it settles without a report, classify and route that failed attempt before returning to this step. Done when the current child has settled and its report is collected.
5. **Validation.** All of these must hold:
   - `git diff --exit-code <lock_sha> -- <locked paths>` exits 0 (skip on the checks-only path);
   - the test command is green (skip when `ticket.md` names none);
   - each planned [calibration](#calibration) is **calibrated** for the current protected code, tests, and fixtures;
   - every applicable check in `ticket.md` passes, run by you, not taken from the report;
   - the worktree is clean, and the branch tip has moved past `lock_sha`, or past `base_sha` on the checks-only path. For a test-only correction, the accepted test commit must move past its preparation `base_sha`; unchanged correct production needs no new commit.

   First check the lock, clean committed state, and green test command. Then run pending calibration before the broader checks. A failed condition is a **rejection**: classify it before routing. For an implementation defect, restore any changed locked files (`git restore --source=<lock_sha> --staged --worktree -- <locked paths>` and commit only when that creates a diff), then use the [ladder](#escalation-ladder). The rejected attempt's other commits stay on the branch. A suspect test goes to the test-writer path, not another implementer. Done when all conditions hold for the same accepted state.

Report to the caller: `lock_sha` or the checks-only verdict, the final branch tip, each check and calibration verdict with its result, any named uncalibrated boundary, and the run directory.

### Entering mid-chain

A caller with review findings for a ticket that already ran the chain enters at a later step, with a fresh child per phase:

- A **behavior gap** (the code is wrong and no test catches it): add the criterion and its verdict to `ticket.md`, run step 3 to extend the lock, then steps 4 and 5.
- A **code-only finding**: add it to the criteria in `ticket.md`, then run steps 4 and 5 against the existing lock.
- A **suspect test** (wrong oracle, false green, or contradictory fixture): record the counterexample, run step 3 to re-lock, then step 5 if the corrected tests are green. Run step 4 only if they expose an implementation defect. Internal re-locks keep the current batch and its budgets.

Each caller-supplied review batch runs steps 1-2 for its findings, picks its implementer's starting tier from those criteria, records it in `ticket.md`, and climbs the same ladder.

## Accepting the lock

Check every condition before accepting or rejecting preparation:

- **Scope:** `git diff --name-only <base_sha> HEAD` lists only allowed test paths and fixtures, and the worktree is clean.
- **Results:** each new test is red on its behavior assertion, or is a negative or aggregate case with an [uncalibrated assertion](#calibration). On a first lock or behavior gap, the test command must include red for missing behavior. Setup, import, and syntax failures reject the attempt. Corrected tests on a re-lock may already be green.
- **Oracle:** each test matches its report's oracle line; the line holds against the oracle gate and the false-green rules in `~/.claude/shared/testing.md`.
- **Controls:** rerun every command in the report's Controls table. Check status and actual output against the independent expected result. Confirm coverage of the helpers and fixtures required by the brief; a missing control is a rejection. For unavailable live dependencies, follow the repository's verification rules and report the exact unverified boundary.
- **Plan:** each uncalibrated negative or aggregate assertion has an owner test and a finite regression plan in `ticket.md`.

## Calibration

An assertion is **uncalibrated** until an observed regression makes it red for its stated reason. A test that is green before production exists, or stops at an earlier assertion, provides no such evidence for the protected assertion.

Use this branch for uncalibrated negative or aggregate assertions, or a masking helper or fixture found in review. Confirm the preparation report's finite plan in `ticket.md`: criterion, owner test, protected assertion, smallest regression, and mutation paths. A known-bad revision or an already observed faithful mutation can supply the same evidence while the protected state is unchanged.

After the lock and test command pass, record `calibration_sha` and start a fresh **test writer in calibrate mode** ([brief](test-writer.md#calibrate)). Give it the planned temporary production paths. Tests and fixtures stay unchanged; the child returns the branch to `calibration_sha` before reporting, including on failure.

Inspect the saved mutation diff and command logs, not only the report's verdict. Check that each mutation recreates the named regression and that its logged status and failure identify the protected assertion. Require unchanged HEAD, `git diff --exit-code <calibration_sha>`, a clean worktree, and the green test command run by you. Each named regression needs red on its protected assertion and green after restoration. Complete only the agreed list; this is not an open-ended mutation search.

- **Calibrated:** record the commands, results, and protected state in Verdicts. Reuse this evidence until that code, its owner tests, fixtures, or regression plan changes.
- **Suspect test:** a faithful regression stayed green. Use the calibration re-lock route in [failure classification](#escalation-ladder), then rerun affected calibration. Use an implementer only if corrected tests expose a code defect.
- **Blocked:** no faithful regression or required environment can be established, or restoration cannot be verified. Diagnose and report the limit; a skipped or setup-failing mutation is not calibrated. Use [failure classification](#escalation-ladder) rather than rejecting correct production.

## Dispatch

Every child runs on OpenCode with an `openai/*` model. The tier picks the model: use the OpenCode column of `~/.claude/shared/model-tiers.md`.

Write the child's prompt to `<role>-<n>.prompt.md`. It carries pointers only, never pasted history:

```text
Role: <test writer | implementer>, attempt <n>.
Mode: <prepare | calibrate>   <- test writer only
Read your brief first and follow it: <absolute path to test-writer.md or implementer.md>.
Ticket: <run-dir>/ticket.md (its Verdicts section lists earlier attempts and why they were rejected).
Lock: <run-dir>/lock.json   <- when a lock exists: implementer, or a test writer that re-locks or extends it
Narrow repair: <Verdicts entry>   <- narrow repair only
Exclusive file scope: <allowed test paths and fixtures | planned temporary production paths | the whole checkout>   <- prepare | calibrate | implementer
Report: write <run-dir>/<role>-<n>.report.md atomically (write .tmp, then rename).
Work in <checkout> on branch <branch>. Commit prepare and implementation work. Calibration restores <calibration_sha> without commits. Do not push.
```

Choose the launch mode in this order:

1. `HERDR_ENV=1` and `HERDR_CHILD_PARENT_PANE` is unset: start a visible tab with `herdr-child start --kind opencode --posture rw --model <model> --cwd <checkout> --prompt-file <prompt> --detach`. Tabs avoid the narrow-pane OpenCode hang. Follow the parent duties in `~/.claude/shared/child-agent-contract.md`; the supervision marker wakes you. Answer a child's `herdr-child ask` from `ticket.md`; pass it to the user only when it needs a product decision. A herdr child goes straight to mode 2 because `herdr-child start` refuses to run from a child pane.
2. `opencode` is on `PATH`: run `opencode run --dir <checkout> -m <model> --auto --format json "$(cat <prompt>)" < /dev/null > <run-dir>/<role>-<n>.jsonl 2>&1` as a background process that re-invokes you on exit (in Claude Code, the Bash tool's `run_in_background`). The stdin redirect prevents `opencode run` from waiting for EOF. `~/.claude/shared/long-running-work.md` owns its supervision.
3. Otherwise no child can start. Stop.

When no child can start, or a start fails, report the reason to the caller and stop. The orchestrator never writes the child's work itself.

The child's answer is its report file. Pane text and the JSONL log are evidence for diagnosis, never the answer. A child that settles without a report has failed its attempt. In herdr mode, reap each child with `herdr-child reap` in the turn that reports its result, following the lifecycle rule of the `herdr` skill. In headless mode, confirm the process has exited before the next phase starts.

## Escalation ladder

Record every failed attempt in Verdicts before selecting the next child. Classify from observed evidence, not the child's claimed success:

| Cause | Route |
|---|---|
| Test or fixture defect | Fresh prepare-mode test writer one tier up; a failure on high may use narrow repair. |
| Implementation defect with a valid lock | Fresh implementer one tier up. |
| Faithful calibration regression stays green | Record the counterexample. If the calibration re-lock budget is available, consume it and use a fresh prepare-mode writer on high in the current batch. Otherwise stop. |
| Calibration execution defect: wrong mutation, incomplete evidence, or failed restoration | Recover and verify the recorded production snapshot first; then a fresh calibrate-mode test writer one tier up. Keep the lock. A failure on high stops the chain. |
| Confirmed environment or caller-brief defect | Diagnose and correct the prerequisite. If that role's prerequisite retry is available, consume it and retry on the same tier. Otherwise stop. An unresolved prerequisite also stops the chain. |
| Missing oracle or product decision | Return to the oracle gate for zero tests, or ask the caller for the required decision. No model escalation. |

The ladder is low → medium → high. Never xhigh. Diagnose a missing report from process state and logs first; without evidence of an environment failure, it consumes a normal failed attempt. Launch failures still follow Dispatch.

- The test writer starts on medium.
- The implementer starts on low when the ticket's production change touches one file. Every other ticket starts the implementer on medium. Count only production files; tests and fixtures written by the test writer do not count. Record the tier and its reason under Implementer start in `ticket.md`.
- Before an implementer goes to high, inspect any existing lock for a suspect test. Record its counterexample and send it to a fresh prepare-mode writer on high to re-lock. Follow the suspect-test route under [Entering mid-chain](#entering-mid-chain); start the high implementer only if corrected tests expose a code defect.
- A failure on high stops the chain unless it qualifies for a prerequisite retry or prepare-mode narrow repair. Report the blocker and ask the user.

### Batch budgets

A **batch** is the caller's initial ticket or one caller-supplied set of new review findings. Initialize its numbered record in `ticket.md`. Internal retries, re-locks, and calibration keep that batch.

| Budget | Limit |
|---|---|
| Narrow repair | One high-tier prepare-mode repair attempt. Its failure stops the chain regardless of cause. |
| Calibration re-lock | One preparation attempt triggered by a faithful mutation staying green. A subsequent suspect result stops the chain. |
| Prerequisite retry | One same-tier retry per role for a confirmed environment or caller-brief defect. Prepare and calibrate share the test-writer role's budget. |

Mark a budget **used** before launching its child. A new caller-supplied batch initializes new budgets; internal rerouting cannot do so.

### Narrow repair

A high-tier preparation failure may use narrow repair when all of these hold:

- All acceptance conditions were checked, and every found defect has a reproduction and an independent expected result.
- The candidate is clean, committed, preserved in the ref recorded before reset, and changes only the allowed test paths and fixtures.
- The fix fits those existing scenarios and interfaces. An unknown oracle, out-of-scope work, or a test-suite redesign does not qualify.
- The current batch's narrow repair budget is available.

Consume the budget and launch a fresh **high** prepare-mode writer. Its prompt points to the Verdicts entry with the candidate ref, scoped paths, reproductions, and controls. From the preparation `base_sha`, the child restores those candidate paths, fixes the listed mechanisms, and passes full lock acceptance again.

## ticket.md

```markdown
# <ticket id>: <title>

## Ticket
<the ticket text, verbatim>

## Criteria
1. <validation criterion>

## Oracle gate
1. test: <consumer> / <observable failure> / <independent oracle>
2. no test: <reason>

## Seams
1. <public boundary>; paths: <test files and fixtures>

## Commands
- Tests: <command>
- Checks: <each applicable check from the repository's verification rules>

## Implementer start
- <low | medium>: <the one production file | the production files the change touches>; reason: <why this tier applies>

## Batch
- <number>: <initial ticket | caller-supplied review findings>
- base_sha: <HEAD before implementation, on the checks-only path>
- Narrow repair: <available | used>
- Calibration re-lock: <available | used>
- Prerequisite retry: <test writer: available | used>; <implementer: available | used>

## Calibration
- <criterion>; owner: <test>; assertion: <protected result>; regression: <smallest faithful change>; paths: <temporary production paths>; command: <focused test>
- <none, with reason | named unavailable boundary and coverage limit>

## Verdicts
- test-writer-1 (medium): accepted, lock <sha>; report test-writer-1.report.md
- implementer-1 (low): rejected, <reason>; report implementer-1.report.md
- test-writer-2 (high, prepare): rejected, <reproduction>; candidate <ref>; narrow repair <eligible | ineligible, reason>
- test-writer-3 (high, prepare, narrow repair): accepted, lock <sha>; report test-writer-3.report.md
- test-writer-4 (medium, calibrate): <calibrated | suspect test | blocked>; state <sha>; report test-writer-4.report.md
```

## The lock

`lock.json` records the lock that step 5 checks:

```json
{
  "base_sha": "<HEAD before the test writer>",
  "lock_sha": "<branch tip after the accepted test writer>",
  "paths": ["<each file the test writer changed>"]
}
```

A re-lock sets `base_sha` and `lock_sha` from the new test writer and adds the files it changed to `paths`; earlier lock SHAs stay in the Verdicts section. A path stays locked once locked. The diff check is the only enforcement of the lock.
