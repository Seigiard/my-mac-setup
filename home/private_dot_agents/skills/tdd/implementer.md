# Implementer brief

You write the production code for one ticket. When `lock.json` exists, its tests are the specification: you are done when they are **green** and the criteria in `ticket.md` hold. Without a lock, the applicable checks in `ticket.md` validate your work.

## Inputs

- `ticket.md`: the ticket, its criteria, the seams, the test command, and the applicable checks. Its Verdicts section lists earlier attempts and why they were rejected; read the reports it names before you start.
- `lock.json`, when your prompt names it: `lock_sha` and the locked `paths`.
- The branch may carry an earlier rejected attempt's commits; its report says why it failed. Keep or revert that code as the criteria require.
- For a targeted fix: the diagnosis your prompt names in Verdicts, with the reproduction, the independent expected result, the paths you may change, and the control that confirms the fix. Continue from the current branch tip. When the diagnosis names a preserved ref, first restore its named paths (`git restore --source=<ref> --staged --worktree -- <paths>`); locked paths stay at the lock. Change only what the diagnosis names.

## The lock

Every locked path stays byte-identical to `lock_sha`. The orchestrator checks this with `git diff --exit-code <lock_sha> -- <paths>`, and any difference rejects your whole attempt. When a locked test looks wrong, keep it as it is and put the evidence in your report: the test, what it expects, and why the ticket says otherwise. The orchestrator decides what happens to the test.

Other test files follow the red-test rules in `~/.claude/shared/testing.md`. A change to one needs its justification in your report.

## Work

1. Make the smallest change that turns the locked tests green and satisfies the criteria. Every final change must be necessary for a criterion in `ticket.md`; `Non-goals` lists what stays unchanged. Added capabilities and unrelated refactors are out of scope. Usual forms include a new abstraction, option, compatibility path, or support for a case the ticket does not name; these are examples, not absolutes.
2. When `ticket.md` names a test command, run it on your final state. For the other applicable checks in `ticket.md`, run each one that has no [valid evidence](SKILL.md#evidence) for the state your changes affect.
3. Commit on the current branch. Do not push.

Done when the test command is green (when `ticket.md` names one), the applicable checks pass, and the work is committed. When you cannot get there, stop and report what blocks you.

## Report

Write the report to the path in your prompt. Include:

- the files you changed, one line each on why and the criterion it serves, or `consequence of <criterion>` for a lockfile, glossary, or generated state; report a necessary change that violates a non-goal as a conflict;
- the test command and each check with its [valid evidence](SKILL.md#evidence): the tested commit and the log or tool output with its exit status; for a reused result, the run it comes from;
- any locked test you believe is wrong, with the evidence;
- anything left undone.

Save temporary control scripts and their output under the run directory's `controls/`; they need no repository commit. When the orchestrator resumes you for missing report items, keep your commit and add only what it names.

End with the commit SHA.
