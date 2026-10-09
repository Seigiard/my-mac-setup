---
name: tdd
description: Test-first implementation of one ticket through a delegated chain — oracle gate, a test-writer child locks failing tests, an implementer child turns them green. Use to build a feature or fix a bug test-first (red-green), or when another skill hands a ticket or a review fix to the chain.
---

# Test-driven development

You are the **orchestrator** of one ticket. You decide what is tested, start one fresh child per phase, and verify each result. Children write every test and every line of production code. You write only the run directory, the lock record, and the restore of locked files.

## Before the chain

- Work on the ticket branch the caller gave, or the current branch. Start from a clean worktree (`git status --porcelain` is empty), so every diff belongs to one child.
- Use the caller's run directory, or create `~/.claude/artifacts/tdd-<YYYYMMDD-HHMMSS>/<ticket>/`, where `<ticket>` is the issue number or a short slug. It holds:
  - `ticket.md`: the ticket and every decision about it ([layout](#ticketmd)).
  - `lock.json`: the lock record ([layout](#the-lock)).
  - `<role>-<n>.prompt.md` and `<role>-<n>.report.md`: one prompt and one report per child, numbered per role from 1.
- Write every file there atomically: write `<file>.tmp`, then rename it.

## The chain

1. **Oracle gate.** For each validation criterion, decide whether a permanent test is warranted. Apply the repository's test-oracle gate when it has one (in my-mac-setup: `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`) and the oracle rule in `~/.claude/rules/testing.md`. Each criterion gets one of two verdicts, and both are complete paths:
   - **test**: the consumer, the observable failure, and the independent oracle, on one line.
   - **no test**: the reason. The usual cases are agent-facing text (skills, instruction docs), a verbatim copy or move, config with no observable behavior, and behavior owned by an upstream system; `~/.claude/rules/testing.md` carries the reasoning.

   Done when every criterion in `ticket.md` carries a verdict. When no criterion is marked **test**, step 2 records only the checks, step 3 is skipped, and validation rests on the applicable checks alone.
2. **Criteria and seams.** For each **test** criterion, write the seam: the public boundary the test drives, the test file paths and fixtures the test writer may touch, and the command that runs the tests. Read `GLOSSARY.md` and the ADRs in the area when they exist. When the shape of the interface is itself in question, call the Skill tool with "codebase-design" for the seam vocabulary. Ask the user only when a seam needs a product decision. Done when `ticket.md` names the seam, the allowed paths, and the test command for every **test** criterion, plus the applicable checks for the whole ticket.
3. **Test writer.** Record `base_sha` (`git rev-parse HEAD`) and start a test-writer child ([dispatch](#dispatch), brief: `test-writer.md` in this skill's directory). When it settles, accept its work only if:
   - `git diff --name-only <base_sha> HEAD` lists only the allowed test paths and fixtures, and the worktree is clean;
   - the test command fails, and each new test fails on an assertion about the missing behavior, not on a setup, import, or syntax error;
   - each test matches its oracle line and passes the false-green rules in `~/.claude/rules/testing.md`.

   On acceptance, write the [lock](#the-lock): the branch tip becomes `lock_sha`, and the changed files become the locked paths. A criterion the test writer returned with zero tests moves to **no test**, with its reason. When none of the tests survive, no lock exists and the ticket follows the checks-only path.
4. **Implementer.** Start an implementer child (brief: `implementer.md` in this skill's directory). It writes code until the locked tests pass and the criteria hold.
5. **Validation.** When the implementer settles, all of these must hold:
   - `git diff --exit-code <lock_sha> -- <locked paths>` exits 0 (skip on the checks-only path);
   - the test command is green;
   - every applicable check in `ticket.md` passes, run by you, not taken from the report;
   - any change to an unlocked test file is justified in the report under the red-test rules of `~/.claude/rules/testing.md`.

   A failed condition is a **rejection**. Restore the locked files (`git restore --source=<lock_sha> --staged --worktree -- <locked paths>`, then commit), record the verdict, and start a fresh implementer one rung up the [ladder](#escalation-ladder). Done when all conditions hold on one implementer's result.

Report to the caller: `lock_sha` or the checks-only verdict, the final branch tip, each check with its result, and the run directory.

### Entering mid-chain

A caller with review findings for a ticket that already ran the chain enters at a later step, with a fresh child per role per round:

- A **behavior gap** (a criterion the tests do not cover): add the criterion and its verdict to `ticket.md`, run step 3 to extend the lock, then steps 4 and 5.
- A **code-only finding**: record it in `ticket.md`, then run steps 4 and 5 against the existing lock.

Review-fix implementers climb the same ladder.

## Dispatch

Every child runs on OpenCode with an `openai/*` model. The tier picks the model: use the OpenCode column of the complexity table in `~/.claude/shared/herdr-peer-launch.md`. The ceiling is **high**; never xhigh.

Write the child's prompt to `<role>-<n>.prompt.md`. It carries pointers only, never pasted history:

```text
Role: <test writer | implementer>, attempt <n>.
Read your brief first and follow it: <absolute path to test-writer.md or implementer.md>.
Ticket: <run-dir>/ticket.md (its Verdicts section lists earlier attempts and why they were rejected).
Lock: <run-dir>/lock.json   <- implementer only, when a lock exists
Report: write <run-dir>/<role>-<n>.report.md atomically (write .tmp, then rename).
Work in <checkout> on branch <branch>. Commit your work. Do not push.
```

Choose the mode in this order:

1. `SE_EXTERNAL_LEG` is non-empty: you are inside a leg and no child can start. Stop.
2. `HERDR_ENV=1`: start a visible pane with `herdr-child start --kind opencode --posture rw --model <model> --cwd <checkout> --prompt-file <prompt> --detach`. Follow the parent duties in `~/.claude/shared/child-agent-contract.md`; the supervision marker wakes you.
3. `opencode` is on `PATH`: run `opencode run --dir <checkout> -m <model> --auto --format json "$(cat <prompt>)" > <run-dir>/<role>-<n>.jsonl 2>&1` as a background process that re-invokes you on exit (in Claude Code, the Bash tool's `run_in_background`). `~/.claude/shared/long-running-work.md` owns its supervision.
4. Otherwise no child can start. Stop.

When no child can start, or a start fails, report the reason to the caller and stop. The orchestrator never writes the child's work itself.

The child's answer is its report file. Pane text and the JSONL log are evidence for diagnosis, never the answer. A child that settles without a report has failed its attempt. In herdr mode, reap each child with `herdr-child reap` in the turn that reports its result, following the lifecycle rule of the `herdr` skill. In headless mode, confirm the process has exited before the next phase starts.

## Escalation ladder

One child per phase, each fresh. Every failed attempt moves one rung and adds a line to the Verdicts section of `ticket.md`.

| Rung | Who | Tier |
|---|---|---|
| 1 | Test writer | medium |
| 2 | Implementer, attempt 1 | low |
| 3 | Implementer, attempt 2 | medium |
| 4 | You inspect the locked tests. A suspect test (wrong oracle, false green, unreachable seam, or a contradiction with the ticket) goes to a fresh test writer on high, then re-lock. | high (test writer) |
| 5 | Implementer, attempt 3 | high |
| 6 | Stop and ask the user | — |

- A rejected test writer at rung 1 gets one fresh retry on medium. A second rejection stops the chain and goes to the user.
- When rung 4 finds no suspect test, go straight to rung 5.
- The checks-only path skips rungs 1 and 4: implementer on low, then medium, then high, then the user.

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

## Verdicts
- test-writer-1 (medium): accepted, lock <sha>
- implementer-1 (low): rejected, <reason>
```

## The lock

`lock.json` records the lock that step 5 checks:

```json
{
  "base_sha": "<HEAD before the test writer>",
  "lock_sha": "<branch tip after the accepted test writer>",
  "paths": ["<each file the test writer changed>"],
  "superseded": ["<earlier lock_sha values, oldest first>"]
}
```

A re-lock sets `base_sha` and `lock_sha` from the new test writer, adds the files it changed to `paths`, and appends the old `lock_sha` to `superseded`. A path stays locked once locked. The diff check is the only enforcement of the lock.
