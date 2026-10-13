# Run directory

The `tdd` orchestrator's files for one ticket. The `<run-id>` is the run directory's path relative to `~/.claude/artifacts/` (for example, `tdd-20261013-120000/495`). Publish `ticket.md`, `lock.json`, prompts, and reports through a temporary file and an atomic rename: write `<file>.tmp`, then rename it. Execution logs may stream while the child runs.

| File | Holds |
|---|---|
| `ticket.md` | the ticket and every decision about it (layout below) |
| `lock.json` | the lock record (layout below) |
| `<role>-<n>.prompt.md`, `<role>-<n>.report.md` | one prompt and one report per child, numbered per role from 1 |
| `<role>-<n>.jsonl` | the headless child's log, when launched with `opencode run` |
| `controls/`, `calibration-<n>.*` | temporary control scripts, their output, and saved mutation diffs and logs |

## ticket.md

```markdown
# <ticket id>: <title>

## Ticket
<the ticket text, verbatim>

## Symptom
- observed: <the wrong behavior the ticket reports, and the command or scenario it gives>
- expected: <the behavior the ticket expects>
- criterion: <number>
- observation: <for a symptom criterion marked no test: command or scenario, state, output>

## Criteria
1. <validation criterion>

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

## Implementer start
- <low | medium>: <the one production file | the production files the change touches>; reason: <why this tier applies>

## Batch
- <number>: <initial ticket | caller-supplied review findings>
- batch_start_sha: <HEAD when this batch opened; preserved across retries and re-locks>
- turns: <count so far> / <limit, default 8>

## Calibration
- <criterion>; owner: <test>; assertion: <protected result>; regression: <smallest faithful change>; paths: <temporary production paths>; command: <focused test>
- <none, with reason | named unavailable boundary and coverage limit>

## Verdicts
- test-writer-1 (medium, prepare): rejected; D1 test preparation: <assertion or boundary>; repro: <command and observed result>; expected: <independent result>; candidate <ref>; report test-writer-1.report.md
- test-writer-2 (medium, prepare, targeted fix D1): accepted, lock <sha>; report test-writer-2.report.md
- implementer-1 (low): D2 handoff: <missing items>; resumed; then accepted, tip <sha>; evidence <log paths>
- test-writer-3 (medium, calibrate): <calibrated | suspect test | blocked>; state <sha>; report test-writer-3.report.md
```

`Symptom` exists only when the ticket reports a bug.

A diagnosis ID is never reused. A later entry that cites an earlier ID (`D1 returned`) records a return; a new reproduction gets a new ID.

## lock.json

```json
{
  "base_sha": "<HEAD before the test writer>",
  "lock_sha": "<branch tip after the accepted test writer>",
  "paths": ["<each file the test writer changed>"]
}
```

A re-lock sets `base_sha` and `lock_sha` from the new test writer and adds the files it changed to `paths`; earlier lock SHAs stay in Verdicts. A path stays locked once locked.
