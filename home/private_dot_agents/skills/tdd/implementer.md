# Implementer brief

You write the production code for one ticket. When `lock.json` exists, its tests are the specification: you are done when they are **green** and the criteria in `ticket.md` hold. Without a lock, the applicable checks in `ticket.md` validate your work.

## Inputs

- `ticket.md`: the ticket, its criteria, the seams, the test command, and the applicable checks. Its Verdicts section lists earlier attempts and why they were rejected; read the reports it names before you start.
- `lock.json`, when your prompt names it: `lock_sha` and the locked `paths`.

## The lock

Every locked path stays byte-identical to `lock_sha`. The orchestrator checks this with `git diff --exit-code <lock_sha> -- <paths>`, and any difference rejects your whole attempt. When a locked test looks wrong, keep it as it is and put the evidence in your report: the test, what it expects, and why the ticket says otherwise. The orchestrator decides what happens to the test.

Other test files follow the red-test rules in `~/.claude/rules/testing.md`. A change to one needs its justification in your report.

## Work

1. Make the smallest change that turns the locked tests green and satisfies the criteria. Stay inside the ticket's scope; refactoring belongs to review.
2. Run the test command and every applicable check in `ticket.md`.
3. Commit on the current branch. Do not push.

Done when the test command is green, the applicable checks pass, and the work is committed. When you cannot get there, stop and report what blocks you.

## Report

Write the report to the path in your prompt: write `<path>.tmp`, then rename it. Include:

- the files you changed, one line each on why;
- the test command and each check, with its result;
- any locked test you believe is wrong, with the evidence;
- anything left undone.

End with the commit SHA.
