---
title: "Preserve each Verification Contract command's working directory in the se-work gate"
short_description: "The fallback parser drops package working directories, causing run-1787064382632 to fail after a paid work leg even though all six verification rows passed from their declared directories."
type: "bug"
category: "se-pipeline"
tags: ["se-pipeline","bug"]
date: "2026-08-18"
status: "open"
priority: "high"
---

## Why this exists

The `se-work` pipeline can turn a valid multi-package Verification Contract into an invalid work-gate command. The fallback parser in `home/private_dot_claude/dot_smithers/workflows/lib/plan.ts:245-277` extracts backticked command spans from each table row, wraps every extracted command in a subshell, and joins them with `&&`. It does not preserve a working directory stored separately from the command, such as a table column that says to run a Vitest row from `engine/api` or `console`.

This failed `run-1787064382632` for the local client-console-login plan. The work gate ran the engine and console Vitest rows from the repository root, where Vitest could not find their package configs, instead of from `engine/api` and `console`. The pipeline marked the work stage red even though a manual replay of all six Verification Contract rows from their declared directories passed:

- 49 root script tests.
- 70 engine tests, including 6 real-Postgres dev-seed tests.
- 15 console tests.
- Both package typechecks.
- The code-quality contract gate.
- The security contract gate.

The false red gate parks the durable run after the paid work leg. Approving the gate cannot recover it because the derived validate command is fixed when the run starts, so a retry runs the same commands from the same wrong directories. The operator must abort a verified branch, pay for a redundant work leg in a new run, or finish the remaining stages outside the pipeline.

The implemented work survived on branch `se/2026-08-18-001-feat-local-client-console-64382632`. This prevents code loss, but it does not make the pipeline result correct. At the time of the failure, the plan still had two real gaps: the U3 engine controller test additions and the U5 sequential real-browser acceptance capture. A false environmental failure obscures that distinction between verified implementation, incomplete plan items, and an invalid gate command.

The primary `validate_commands:` format already requires package scope to be embedded as `cd <package> && ...` in `home/private_dot_claude/skills/se-plan/SKILL.md:38-73`. This incident shows that the requirement is not enforced end to end. A plan can still reach `se-work` through the Verification Contract fallback with directory context represented outside the command, and gate 0 accepts it as runnable.

## Scope

- Define one canonical representation for a runnable verification row: the command must carry its execution directory, or the parser must return structured `{ command, cwd }` entries instead of plain strings.
- Make gate 0 refuse ambiguous package commands before staging or any paid work leg. The refusal must name the affected command and tell the operator to embed `cd <path> && ...` or declare an equivalent working directory.
- Preserve the directory of every command when the pipeline builds the subshell chain. Each row must remain isolated so one row's `cd` cannot leak into the next row.
- Harden `/se-plan` so generated `validate_commands:` entries include the directory for every package-scoped Verification Contract row, even when the human-readable table keeps the directory in a separate column.
- Add regression tests in `home/private_dot_claude/dot_smithers/workflows/lib/plan.test.ts` for root, `engine/api`, and `console` rows in one contract. The derived gate must execute each row from its intended directory or refuse the plan before launch.
- Update `docs/se-pipeline.md` to state whether a separate working-directory column is supported or rejected. The documented contract and gate-0 behavior must agree.

## Open decisions

- Whether the fallback parser should understand a named working-directory table column or reject it and require `cd <path> && ...` inside every command. Rejection is smaller and keeps `validate_commands:` as the only machine-readable form; structured parsing accepts more existing plans but extends the markdown heuristic.
- Whether gate 0 can reliably detect an unscoped package command. A generic command such as `bun test` is valid at some repository roots, so detection may require explicit row metadata rather than command inspection.
- Whether `/se-plan` should fail its own final checks when a package-scoped row and its `validate_commands:` entry disagree. A warning leaves the same failure available to the next run.
- Whether a red work gate caused by an invalid derived command should permit the operator to replace the validate command and resume from verification, instead of paying for another work stage. This is recovery after a bad launch and does not replace the gate-0 fix.
