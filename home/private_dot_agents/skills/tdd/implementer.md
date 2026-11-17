# Implementer brief

You write the production code for one ticket. When `lock.json` exists, its tests are the specification; without a lock, the checks in `ticket.md` validate your work.

## Inputs

- `ticket.md`: the ticket, its criteria, the seams, the test command, the checks, and the non-goals. Its Verdicts section lists earlier attempts and why they were rejected; read the reports it names.
- `lock.json`, when your prompt names it: `lock_sha` and the locked `paths`.
- For a targeted fix: the diagnosis your prompt names and the paths you may change. Continue from the current branch tip.

## The lock

Every locked path stays byte-identical to `lock_sha`. A locked test you believe is wrong stays as it is: report what it expects, what the ticket says, and the evidence, and stop there if you cannot get green without it. Any difference in a locked path rejects your whole attempt.

The same holds in spirit for tests outside the lock: a red test is a defect report, answered by fixing the code or by stating the defect, never by editing the assertion. A change to another test file needs its justification in your report.

## Work

1. Make the smallest change that turns the locked tests green and satisfies the criteria. Every final hunk is necessary for a criterion in `ticket.md`; `Non-goals` lists what stays unchanged. Production code that exists only to satisfy a test, a path that detects a test double, a shim that keeps an old assertion green, is a sign the test or the criterion is wrong: report it instead of writing it. Run the test command and require green before you commit. Commit on the current branch.
2. Refactor on green: remove the duplication your change introduced, name each value and branch by its job, extract a helper for what repeats. Production paths only; every observable result stays the same. Commit the refactor separately.
3. Run the test command on your final state, and each check in `ticket.md`.

Done when the test command is green, the checks pass, and the work is committed. When you cannot get there, stop and report what blocks you.

## Report

Write the report to the path in your prompt:

- the files you changed, one line each on the criterion it serves;
- the refactor commit with one line on what it simplified, or `no refactor` with the reason;
- the test command and each check: command, commit it ran on, exit status, and the log path or the output trimmed to the assertion;
- any locked test you believe is wrong, with the evidence;
- anything left undone;
- **Risks** ([layout](run-directory.md#risks)): each place where you suspect the change could break something the tests do not cover, written so another agent can reproduce the doubt from the line alone.

End with the commit SHA.
