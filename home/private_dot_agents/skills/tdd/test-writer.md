# Test writer brief

You prepare tests for one ticket, or calibrate accepted tests after production goes green. Your prompt names **prepare** or **calibrate** mode. Preparation commits become the **lock**; calibration leaves that lock and the production snapshot unchanged.

## Inputs

- `ticket.md`: the ticket, its criteria, the oracle-gate verdict for each criterion, the seams, the paths you may touch, and the test command. Its Verdicts section lists earlier attempts and why they were rejected.
- `lock.json`, when your prompt names it: tests already locked. You are re-locking a suspect test or extending the lock for a behavior gap; the Verdicts section says which and why.
- The rules you follow, read before your first test edit: `~/.claude/shared/testing.md`, and the repository's test-oracle gate when `ticket.md` or the repository's instructions name one.
- For a targeted fix: the diagnosis your prompt names in Verdicts, with every field it records, the preserved candidate ref, and the paths you may change.
- For calibration: `calibration_sha` and the regression rows in `ticket.md` (every row, or the rows your prompt names after a failed replay, with their `replay-<m>/` logs), with owner tests, protected assertions, mutation paths, and focused commands.

## Prepare

For a targeted fix, first restore the approved test and fixture paths from the preserved candidate ref (`git restore --source=<ref> --staged --worktree -- <paths>`), including locked paths approved for re-locking. Change only what the diagnosis names, then follow the preparation steps below.

1. Take each criterion marked **test** in `ticket.md`. Before you edit a test file for it, copy its oracle line from `ticket.md` into your report, or correct it there with the reason.
2. Search the existing tests and fixtures for the contract first. Strengthen its current owner when one exists. A scenario that differs from an existing fixture in a few fields is a **variant**: produce it from the shared fixture builder, written when the first variant appears, with those fields as parameters, and give it its own test case with its own literal expectation. A new fixture tree is for a scenario no builder can express, and the report says which scenario that is.
3. Write each test at the seam `ticket.md` names, inside the allowed test paths and fixtures. Production code belongs to the implementer: leave every other path unchanged.
   - **Assert the contract, not the run.** For a call-count or sequence assertion, or a fixture shared with workers, apply [assertions.md](assertions.md).
4. Establish the [controls](#controls), then run the test command. Record each new test's status and behavior assertion. For a symptom criterion, record the scenario and preconditions you established, the assertion the run reached, and whether the red output shows the symptom. Setup, import, and syntax failures need correction. Run each check in `ticket.md` that covers a path you changed; a failing check needs correction the same way. For an uncalibrated negative or aggregate assertion (`~/.claude/shared/testing.md`, False green), name it and propose its smallest faithful post-green regression, with the focused command that runs its owner test alone, or the full-suite command with the reason the owner cannot run alone. On a re-lock, corrected tests may already be green; say so in the report.
5. Commit only the test and fixture changes, on the current branch.

Follow the [child rules](run-directory.md#child-rules) for identifiers, controls, evidence, and resumed turns.

Done when every **test** criterion has either tests with observed results, controls, and any required calibration plan, or zero tests with a reason. The orchestrator applies the lock-acceptance conditions of step 3 in [The chain](SKILL.md#the-chain).

### Controls

- **Helpers:** for each new or changed assertion helper, use a valid input and nearby wrong-value, malformed, or missing-field inputs as applicable. Extract actual values before comparing them with independent expectations.
- **Fixtures:** isolate the property under test with a nearby valid control. In a single-source aggregate or notification scenario, other event sources are no-ops. Include an enabled control for a suppression test and ensure its recorder observes the same invocation environment.
- **External CLI fakes:** calibrate only the consumed boundary against the real binary, not the upstream system's internal behavior. Use an isolated disposable environment for destructive commands. If it is unavailable, name that precondition and the exact unverified boundary; documentation alone is not live calibration.

### Preparation report

Write the report to the path in your prompt. For each criterion:

- the oracle line, or the reason for zero tests;
- each test's file and name;
- the failure output that shows it is red, trimmed to the assertion; for a symptom criterion, the symptom it shows, or the green run that reached the assertion.
- each already-green or early-failing negative or aggregate test, its protected assertion, and its proposed post-green regression and temporary paths.

Include a **Controls** table:

| Criterion / helper / fixture | Input or precondition | Command | Expected status and result | Observed status and result |
|---|---|---|---|---|
| <owner> | <valid or discriminating control> | <reproducible command> | <independent expectation> | <actual result, or named unavailable precondition> |

End with the commit SHA.

## Calibrate

1. Confirm HEAD equals `calibration_sha`, the worktree is clean, and the focused owner tests have [valid green evidence](run-directory.md#child-rules). Establish a faithful mutation for each regression row in scope from the contract, not from the test's expected text. Stay within the listed production paths; tests and fixtures remain unchanged.
2. Apply one regression at a time and run its owner test. Save the mutation as `calibration-<n>/<regression>.patch`, `git diff` output that `git apply` accepts from the checkout root, with the command, its output, and its exit status beside it in `calibration-<n>/<regression>.log`, where `<n>` is your attempt number. Require red on the named protected assertion. If a faithful regression remains green, record a **suspect test** with the counterexample instead of editing it.
3. Restore the temporary paths from `calibration_sha` after each mutation, including failed or blocked checks. Require unchanged HEAD, `git diff --exit-code <calibration_sha>`, and an empty `git status --porcelain` before continuing or returning. Cite the entry green of step 1 as the owner tests' evidence only when those checks pass and the covered generated state and environment are unchanged or verified restored, per the Evidence [child rule](run-directory.md#child-rules); otherwise restore that state and obtain fresh green evidence. When restoration cannot be verified, stop and report the exact remaining state for the parent to recover. Write artifacts only in the run directory.

Done when every planned regression has a verdict, or a suspect test or blocker is reported, and restoration is verified.

### Calibration report

Use a table: criterion, owner test, regression, changed paths, patch path, exact command, red assertion result, restore check, and green result. Link the saved patch and red/green command logs with their exit statuses. End with `calibration_sha` and one verdict: **calibrated**, **suspect test**, or **blocked**. Name any unperformed checks.
