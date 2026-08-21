---
title: "Decide what a plan owes the pipeline, and whether the pipeline should keep inferring it from prose"
short_description: "Decide what a plan owes the pipeline, and whether the pipeline should keep inferring it from prose"
type: "idea"
category: "testing-ci"
tags: ["testing-ci","idea"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-15"
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

## Resolution

**The plan declares its verification commands; the prose parser stays as the fallback.** A `validate_commands:` YAML list in the plan's frontmatter is read first and used verbatim. A plan without the key falls through to today's `Verification Contract` parser, unchanged — so nothing migrates, and every plan already committed in a target repo keeps running exactly as before.

Changed files:

- `home/private_dot_claude/dot_smithers/workflows/lib/plan.ts` — `deriveValidateCmd` now reads the declaration first (`readDeclaredCommands`, a block-sequence parser scoped to this one key); the derivation carries a `source: "declared" | "parsed" | "none"` field; the segment classifier gained a machine-readable `refusal` cause so the declared path can keep the flag-detected mutation refusal without matching on a message string; `planFrontmatter` is exported as the single definition of where the frontmatter block ends; the gate-0 refusal text moved here as `noValidateCmdRefusal`, so the message that names both shapes is a pure function with tests rather than a string inside a workflow closure.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `frontmatterField` now reads its block through `planFrontmatter`. It stays a single-value line-prefix matcher; `artifact_readiness` / `execution` behave identically.
- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — gate 0 throws `noValidateCmdRefusal(observations)`, which names both shapes and carries a frontmatter example, and logs which shape the command came from (`work-gate validate-cmd [plan frontmatter validate_commands]` vs `[plan Verification Contract]`).
- `home/private_dot_claude/dot_smithers/workflows/lib/plan.test.ts` — 21 cases: verbatim use, filter bypass, mutation refusal, precedence, unchanged fallback, every malformed declaration shape, and the refusal message. Suite: 584 → 605 pass, 0 fail.
- `home/private_dot_claude/skills/se-plan/SKILL.md` — a fourth amendment: the plan it produces emits the declaration. `se-plan` delegates the whole plan body to the plugin skill `compound-engineering:ce-plan`, which this repo cannot edit, so the requirement sits in the wrapper's own amendment list, fired after the plugin writes the artifact and before the post-generation menu.
- `home/private_dot_claude/skills/se-work/SKILL.md` — the preflight and the argument contract name both shapes. `se-review-and-work` restates neither (it defers to `se-work`'s phases), so it needed no edit.
- `docs/se-pipeline.md` — the validate-cmd section documents the declaration as the primary shape with an example, and the parser as the fallback.

The four open decisions were settled as:

- **Declared, with inference kept as the fallback.** Declaration ends the shape guessing for new plans; keeping the parser means no migration and no dead plans. The two coexist without a second format inside the document.
- **Frontmatter carries it, under the key `validate_commands`.** It is the smallest addition: frontmatter is already parsed and already carries `artifact_readiness` / `execution`. The name is snake_case like its neighbours, and names the thing it produces — the operator already knows it as `--validate-cmd` and from the `work-gate validate-cmd [...]` log line. A fenced JSON/YAML block was rejected: a second format inside the document, and it invites the setup command into the plan.
- **The setup command stays an operator flag — decided "no", not omitted.** A plan that carries its own setup command can run an arbitrary install command from a file the pipeline treats as trusted input, which is exactly the boundary KTD8 draws. `--setup-cmd` stays with the operator, who knows what the machine has; the probe of `docs/issues/2026-08-14-013-fresh-worktree-has-no-dependencies.md` keeps reporting the gap.
- **A plan that satisfies nothing gets a refusal that names both shapes.** Gate 0 prints the `validate_commands:` frontmatter form with a one-line example, then the `Verification Contract` section forms the fallback accepts (`##`–`######` heading; table rows, ```` ```bash ```` fenced lines, `-`/`*`/`1.` list items with backticked commands), then what the derivation refused and why.

Two rules the decision implies, both deliberate:

- **Precedence: the declaration wins over the section, and a malformed declaration refuses instead of falling back.** An explicit statement outranks a heuristic recovery; honouring the guess over the statement would make declaring pointless. Plans keep a section written for humans (Covers columns, manual rows) whose runnable subset is what the list holds, so the two disagreeing is ordinary rather than exceptional. Falling back on a malformed declaration would run a command the author never wrote while their typo goes unmentioned — the silent-divergence failure this issue was filed about.
- **The keep-side filter is skipped for declared commands; one refusal survives.** An unrecognised runner is not a finding when the operator declared it, so `notes` is empty on the declared path and nothing lands in `dropped` for it. A *mutating flag* (`--write`, `--fix`, `-i`, `--apply`, matched as a whole argument) is still refused, loudly, at gate 0, naming the flag and the reason: the work gate runs the command and then requires a clean worktree, so a formatter in the gate fails the stage for a reason unrelated to the work. One refused entry refuses the whole launch — every entry of a declared list is deliberate, and running the survivors would verify less than the plan demands while the run still goes green. Mutation detected by *name* (`prettier`, `bun run fmt:check`) does not block a declaration: a whole-argument flag is a fact, a name is a guess, and `fmt:check` is the guess going wrong. A declared non-terminating command is likewise left alone — the pre-work probe executes the validate-cmd once on the base commit, so it surfaces before a paid work leg.

Not settled here: **where the plan lives during a run** stays with `docs/issues/2026-08-14-012-work-agent-escapes-the-isolated-worktree.md`. The declaration changes what the plan says, not how it is delivered to the work agent.
