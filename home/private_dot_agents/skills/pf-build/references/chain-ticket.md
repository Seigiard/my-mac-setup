# Chain ticket

`pf-build` supplies each sub-task's `tdd` run with the following material.

## Ticket

Copy the task file verbatim into `ticket.md` -> Ticket. Its Validation criteria are the chain's criteria.

## Checks

Use these checks for `ticket.md` -> Commands. The `platform` repo has no `docs/agent-verification.md`, so `pf-build` supplies them:

- In each changed package, run `bun run typecheck` and the tests named by the validation criteria, using runners from the repo's `AGENTS.md` -> Testing.
- Run `bun run fix` and leave the worktree clean.
- Rebuild touched contract artifacts with `bun run contracts:build:<name>` and confirm their diff matches the task file.
- When an export, entity, or API surface is removed or renamed, run `bun run build:all` and typecheck every consuming package.

## Repository rules

Append these rules to `ticket.md` -> Ticket under a `### Repository rules` heading:

- Read `AGENTS.md` first and trust it.
- Follow "Making Changes" in each affected `contracts/<name>.md`.
- Stay inside Scope and Out of scope.
- Never rebase or merge another branch.
- Delete a test file only when its subject is the removed behavior.
- Never `.skip` a test.
- Call a failing suite pre-existing only after running the same suite on the base branch and comparing both results.

## PR

The orchestrator uses this format after validation:

- The title starts with `<TASK-ID>: `.
- The body has `## Summary`, `## Problem Reproduction`, `## Solution`, and `## Review Context`.
- Put the orchestrator's step-5 check output under Review Context. Child PRs get no CI.
- Do not attach screenshots. Nested PRs skip visuals.
