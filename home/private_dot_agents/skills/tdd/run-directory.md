# Run directory

The `tdd` orchestrator's files for one ticket. The `<run-id>` is the run directory's path relative to `~/.claude/artifacts/` (for example, `tdd-20261013-120000/495`). Publish `ticket.md`, `lock.json`, prompts, and reports through a temporary file and an atomic rename: write `<file>.tmp`, then rename it. Execution logs may stream while the child runs.

| File | Holds |
|---|---|
| `ticket.md` | the ticket and every decision about it (layout below) |
| `lock.json` | the lock record (layout below) |
| `<role>-<n>.prompt.md`, `<role>-<n>.report.md` | one prompt and one report per child, numbered per role from 1 |
| `<role>-<n>.jsonl`, `<role>-<n>-resume.jsonl` | the headless child's initial log and every resumed turn, appended in order, when launched with `opencode run` |
| `controls/` | temporary control scripts and their output |
| `calibration-<n>/` | the calibrate child's `<regression>.patch` and `<regression>.log`, one pair per plan row; `<n>` is the child's attempt number |
| `replay-<m>/` | the orchestrator's `<regression>.log`, one per plan row; `<m>` counts replays from 1 |

## ticket.md

```markdown
# <ticket id>: <title>

## Ticket
<the ticket text, verbatim>

## Symptom
Repeat this entry once per symptom criterion:
- criterion: <number>
- observed: <the wrong behavior the ticket reports, and the command or scenario it gives>
- expected: <the behavior the ticket expects>
- observation: <evidence when needed: command or scenario, state, output>

## Criteria
1. <validation criterion>; evidence: <ticket sentence, report, log, incident, or reproduced failure>

## Non-goals
- <behavior, file, or area the ticket deliberately leaves unchanged | None explicitly stated, when the ticket names none>

## Oracle gate
1. test: <consumer> / <observable failure> / <independent oracle>
2. no test: <reason>

## Seams
1. <public boundary>; paths: <test files and fixtures>

## Commands
- Tests: <command>
- Checks: <each applicable check from the repository's verification rules>

## Starting tiers
- test writer: <tier>; reason: <selection reason, SKILL.md step 2>
- implementer: <tier>; reason: <selection reason, SKILL.md step 2>

## Batch
- <number>: <initial ticket | caller-supplied review findings>
- batch_start_sha: <HEAD when this batch opened; preserved across retries and re-locks>
- turns: <count so far> / <limit>

## Calibration
- <criterion>; owner: <test>; assertion: <protected result>; regression: <smallest faithful change>; paths: <temporary production paths>; command: <owner test alone | full-suite command; reason: <why the owner cannot run alone>>; patch: <calibration-<n>/<regression>.patch, after the first calibration>
- <none, with reason | named unavailable boundary and coverage limit>

## Verdicts
- test-writer-1 (medium, prepare): rejected; D1 test preparation: <assertion or boundary>; repro: <command and observed result>; expected: <independent result>; source: <authority or missing decision>; cause: <candidate>; cause check: <observation, predicted and observed result>; candidate <ref>; report test-writer-1.report.md
- test-writer-2 (medium, prepare, targeted fix D1): accepted, lock <sha>; report test-writer-2.report.md
- implementer-1 (low): D2 handoff: <missing items>; resumed; then accepted, tip <sha>; evidence <log paths>
- test-writer-3 (medium, calibrate): <calibrated | suspect test | blocked>; state <sha>; report test-writer-3.report.md
- replay-1: calibrated; state <sha>; logs replay-1/
```

Each diagnosis gets a fresh ID. A [return](recovery.md#responding-to-a-failure) is written under the later entry as `D1 returned`.

## lock.json

```json
{
  "base_sha": "<HEAD before the test writer>",
  "lock_sha": "<branch tip after the accepted test writer>",
  "paths": ["<each file the test writer changed>"]
}
```

A re-lock sets `base_sha` and `lock_sha` from the new test writer and adds the files it changed to `paths`; earlier lock SHAs stay in Verdicts. A path stays locked once locked.

## Child rules

Every child, whichever brief it follows:

- **Identifiers:** every commit, range, or repository it records is pasted whole from git output in the repository it names (the checkout when it names none) and resolves there: `git rev-parse --verify <sha>^{commit}` for a commit, and `git merge-base --is-ancestor <base> <head>` exits 0 for a range. A branch name is recorded as the commit it resolves to, or marked unresolved.
- **Controls:** temporary control scripts and their output go under `controls/` and are cited by path; they need no repository commit.
- **Evidence:** valid evidence for a test, check, or control result is the command, its exit status, the code state it ran on, and the output that shows the required scenarios ran; a pass/fail summary alone is not evidence, nor is a skipped or focused run for a required broader suite. It comes from a command that finished inside your turn or from a named earlier run on the same state. A server or watcher started for a test is stopped before the report is published.
- **Checks:** the report lists every check in `ticket.md`, one line each: its valid evidence, or `not covering` with the changed paths and why the check does not reach them; a reused result names the run it comes from.
- **Resumed turns:** when the orchestrator resumes a child for missing report items, the child keeps its candidate or commit and adds only what the orchestrator names.
- **Push:** the child commits on the current branch; pushing belongs to the caller.
