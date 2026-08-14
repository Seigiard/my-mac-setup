---
title: Decide what a plan owes the pipeline, and whether the pipeline should keep inferring it from prose
type: idea
date: 2026-08-14
status: open
---

# The plan format is an undeclared contract inferred from markdown

## Why this exists

The pipeline treats the plan as its authority: gate 0 hashes it, KTD8 trusts it as operator-authored input, KTD7 refuses the run if its content changes mid-flight, and KTD11 reads it from the launcher rather than the worktree so it cannot drift. Every one of those rules is about the plan's *identity*. None of them says what the plan must *contain*, or in what shape.

That shape is instead discovered by parsing prose, and three separate defects filed today all trace back to it:

- `docs/issues/2026-08-14-011-verification-contract-parser-ignores-bullet-lists.md` — the parser read table rows and fenced blocks but not list items, so a correctly-written contract yielded nothing and gate 0 refused a ready launch. Fixed by adding the third shape; the fix is another heuristic on the pile.
- `docs/issues/2026-08-14-010-validate-cmd-filter-is-unsound-in-both-directions.md` — having extracted candidate commands, the filter decides which are real gates by matching tokens and substrings. It drops `oxlint` (the runner's name is not a keep token), drops anything whose path contains `fixtures` (substring collision with `fix`), and admits `oxfmt --write` whenever some other word on the line looks like a test.
- `docs/issues/2026-08-14-012-work-agent-escapes-the-isolated-worktree.md` — the plan's absolute path is handed to the work agent, which then resolves its writes relative to the plan's repository root instead of the worktree.

The heading level already drifted once and was patched (`extractValidateCmd` now accepts H2 through H6). A prose sentence already poisoned a gate once (`run-1784823010502` derived `(test)` from "script is `e2e`, not `test`"). Each patch is locally correct; together they are a parser inferring a contract that nobody wrote down.

The cost lands entirely on the operator, and lands late. A plan that looks complete is refused at gate 0 with no statement of what shape was expected, or — worse — is accepted with a gate command that verifies less than the plan demanded, and the run goes green having proved less than it claims.

## Scope

This is a design decision, not a bug fix. What it must settle:

- **What the pipeline actually requires from a plan.** Today: a `Verification Contract` section yielding at least one runnable command, plus `artifact_readiness: implementation-ready` frontmatter. Whether anything else is required is not written down anywhere the operator reads.
- **Whether that requirement should be declared or inferred.** A machine-readable block (frontmatter fields, or a fenced JSON/YAML region the plan owns) would end the shape guessing outright. It costs plan authors — human and agent — a stricter format, and `/se-plan` would have to emit it.
- **What happens to the heuristics if a declaration exists.** `010`'s open decisions already ask whether the runner filter should exist at all; a declared command list makes most of it unnecessary, because the prose risk it guards against is gone.
- **Backward compatibility.** Plans already committed in target repos are written in the current shapes. A declared format needs either a migration or a documented fallback to today's parser.
- **Where the plan lives during a run.** `012` proposes copying the plan into the worktree. That decision belongs here too: if the plan is a contract, its delivery to the agent is part of the contract.

Files that would change: `home/private_dot_claude/dot_smithers/workflows/lib/plan.ts`, the plan-authoring side in `/se-plan`, and the runbook section on the Verification Contract (`docs/se-pipeline.md`).

## Open decisions

- **Declared vs inferred.** Inference keeps plans readable and lets any markdown plan run; it is also the source of all three defects above. Declaration is unambiguous and cheap to validate, but adds a format that must be taught, generated, and versioned.
- **If declared: what carries it.** Frontmatter is already parsed and already carries `artifact_readiness`, so it is the smallest addition. A fenced block holds more structure (per-gate commands, setup command, timeouts) at the cost of a second format inside the document.
- **Whether the setup command belongs in the plan.** The plan knows what its verification needs; the operator knows what the machine has. `--setup-cmd` is an operator flag today, and the probe from `docs/issues/2026-08-14-013-fresh-worktree-has-no-dependencies.md` only reports the gap. Putting it in the plan makes a plan self-provisioning; it also lets a plan run an arbitrary install command, which is exactly the boundary KTD8 draws.
- **What a plan that satisfies nothing should get.** Gate 0 refuses today with a message that does not name the accepted shapes. Whatever format wins, the refusal must state what was looked for and where.
