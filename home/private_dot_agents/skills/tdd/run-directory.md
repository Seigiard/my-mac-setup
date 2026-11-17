# Run directory

The `tdd` orchestrator's files for one ticket. The `<run-id>` is the run directory's path relative to `~/.claude/artifacts/` (for example, `tdd-20261013-120000/495`). Write `ticket.md`, `lock.json`, prompts, and reports through a temporary file and an atomic rename.

| File | Holds |
|---|---|
| `ticket.md` | the ticket and every decision about it (layout below) |
| `lock.json` | `base_sha`, `lock_sha`, and the locked `paths` |
| `<role>-<n>.prompt.md`, `<role>-<n>.report.md` | one prompt and one report per child, numbered per role from 1 |
| `<role>-<n>.jsonl` | the headless child's log, when launched with `opencode run` |

A re-lock sets `base_sha` and `lock_sha` from the new test writer and adds the files it changed to `paths`. A path stays locked once locked.

## ticket.md

```markdown
# <ticket id>: <title>

## Ticket
<the ticket text, verbatim>

## Symptom   <- bug tickets only
- observed: <the wrong behavior the ticket reports, and the command or scenario that shows it>
- expected: <the behavior the ticket expects>

## Criteria
1. <criterion>; occurrence: <ticket sentence, report, log, transcript line, or incident, with where it happened>; verdict: <test: consumer / observable failure / independent oracle | no test: reason>

## Non-goals
- <behavior, file, or area the ticket leaves unchanged | None explicitly stated>

## Seams
1. <public boundary>; paths: <test files and fixtures>

## Commands
- Tests: <command | not applicable: reason>
- Checks: <each applicable check from the repository's verification rules>

## Tiers
- test writer: <tier>; implementer: <tier>

## False-green risks
- <criterion>; owner: <test>; assertion: <protected result>; form: <why it could stay green>; paths: <production paths a mutation may touch>

## Batch
- <number>: <initial ticket | caller-supplied review findings>; start: <sha>; turns: <count> / <limit>

## Verdicts
- test-writer-1 (medium, base <sha>): rejected; D1 <assertion>: <reproduction>; expected <result>, source <authority>; candidate refs/tdd/<run-id>/test-writer-1; report test-writer-1.report.md
- test-writer-2 (medium, base <sha>, targeted fix D1): accepted, lock <sha>
- implementer-1 (low): accepted, tip <sha>; evidence <log paths>
- correction: <path>:<line>, <old> → <new>; source <file:line or ticket sentence>; lock <sha>
- test-writer-3 (medium, calibrate): calibrated; state <sha>
- implement: start <sha>; chain refs/tdd/<run-id>/chain; sliced tip <sha>
```

## Risks

The last section of every child report and of the orchestrator's report to the caller. One line per item, in the form another agent can act on without this run's context:

```markdown
## Risks
- <path or seam>: <what could be wrong>; reproduce: <command or scenario>; expect: <what a correct system shows>
```

An item names a doubt, not a finding: a boundary the tests do not reach, an assertion that could stay green while the behavior is wrong, an environment the run could not exercise. The caller passes the section to the reviewer or to a fresh agent as its reproduction list.

## Child rules

Every child, whichever brief it follows:

- **Evidence:** a test, check, or control result is the command, its exit status, the commit it ran on, and the output that shows the required scenarios ran. A skipped or focused run is no evidence for a broader suite. A server or watcher started for a test is stopped before the report is published.
- **Identifiers:** every SHA in a report is pasted from git output in the checkout.
- **Resumed turns:** a child resumed for missing work keeps its commit and adds only what the orchestrator names.
- **Push:** the child commits on the current branch; pushing belongs to the caller.
