---
title: "Decide what a pipeline launch should ask the operator for, and delete the rest"
short_description: "Decide what a pipeline launch should ask the operator for, and delete the rest"
type: "idea"
category: "se-pipeline"
tags: ["se-pipeline","idea"]
date: "2026-08-14"
status: "open"
priority: "medium"
---

# The launch surface asks for eleven things the operator cannot know and one it can

## Why this exists

Launching a run means answering a form. `inputSchema` in `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` has **eleven fields**; `se pipeline` exposes **six flags**. The operator, standing in a repository with a plan, reliably knows exactly one of them: which plan.

The eleven, and what answering each actually requires:

| Field | What the operator must know to answer it |
|---|---|
| `planPath` | Which plan. The one real question. |
| `validateCmd` | Derived from the plan when omitted. Passing it means overriding the plan's own contract. |
| `setupCmd` | How the target repo builds workspace dists, *and* that a run worktree lacks them. |
| `until` | Nothing — `pr` is refused (below). |
| `docReview` | Nothing. The schema itself says "The user never types this"; the two skill entrypoints set it. |
| `validateTimeoutMs` | How long the target repo's unit suite takes in a cold worktree. |
| `setupTimeoutMs` | How long that repo's install and build take. |
| `workTimeoutMs` | How long an agent will take on an unseen plan. |
| `workBudgetUsd` | A dollar figure described in its own schema as "NOT a cost target". |
| `smoke` | Nothing — it is a wiring test for developing the pipeline. |
| `smokeSeverity` | Nothing — it injects fake severity into a smoke run. |

Five of the eleven (`setupTimeoutMs`, `workTimeoutMs`, `workBudgetUsd`, `smoke`, `smokeSeverity`) have no launcher flag at all: `se pipeline` never mentions them, and reaching them means bypassing `se` and calling `smithers up --input '<json>'` by hand. They are in the operator-facing schema and are not operator-reachable.

**`--until=pr` is advertised on three surfaces and refused on all of them.** The CLI usage offers `[--until=branch|pr]` and documents "stop stage: branch (default) or pr". The `se-work` skill documents `until:pr` as a supported argument and warns it is outward-facing. Gate 0 then refuses every run that passes it:

```
$ rg -n 'until === "pr"' -A2 home/private_dot_claude/dot_smithers/workflows/lib/gates.ts
70:  if (until === "pr") {
71:    return { ok: false, reason: "--until=pr is not implemented in the MVP; use --until=branch (KTD/R6)." };
```

An operator who follows the documentation gets a refusal at gate 0, which is the cheapest failure the pipeline has and still a wasted round trip on a flag that should not be offered.

**The two flags that matter are the two nobody passes.** Both of today's failed runs died on things a flag would have prevented, and nothing at launch time asked:

- `run-1786717826270` — `vitest` absent in the fresh worktree, exit 127. `--setup-cmd` fixes it. Now caught by the probe added in `docs/issues/2026-08-14-013-fresh-worktree-has-no-dependencies.md`, still not asked for.
- `run-1786718288581` — a workspace package's built dist absent in the fresh worktree, exit 1, twice, $1.83. `--setup-cmd` fixes it. Nothing catches it (`docs/issues/2026-08-14-019-worktree-missing-built-dists-is-not-detected.md`).

So the launch surface is simultaneously too large and too quiet: it offers eleven knobs, hides the two that decide whether the run can work at all, and offers one that cannot work.

**And the surfaces disagree with each other.** `se flow` takes `--budget`; `se pipeline` takes no budget flag (`docs/issues/2026-08-14-015-run-budgets.md`). `se pipeline` takes `--validate-timeout` in seconds while the schema field is `validateTimeoutMs` in milliseconds. `docReview` is not a flag the user types but a choice encoded in *which command they invoked* (`/se-work` versus `/se-review-and-work`), so the entrypoint name is itself a hidden parameter.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — `inputSchema`.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — `cmd_pipeline` and its usage text.
- The `se-work` and `se-review-and-work` skills, which document the argument contract the user actually reads.
- `docs/se-pipeline.md` — the launch section.

## Open decisions

- **What the minimum viable launch is.** The strong position: `se pipeline <plan>` and nothing else, with everything the run needs either derived from the repo, declared by the plan, or asked for interactively when it cannot be determined. Every flag that survives should have a reason an operator would recognise.
- **Which parameters should move into the plan.** `validateCmd` already lives there. `setupCmd` arguably belongs there too — the plan knows what its verification needs — but that lets a plan run an arbitrary install command, which is the boundary KTD8 draws. This overlaps `docs/issues/2026-08-14-014-plan-format-contract.md` and should be decided with it, not separately.
- **Which should be derived instead of asked.** Provisioning is derivable from a lockfile. Timeouts are guesses either way; a default that adapts to the observed duration of the first run is better information than an operator's estimate.
- **Which should be deleted.** `until` has one legal value. `smoke` and `smokeSeverity` are development inputs sharing a schema with operator inputs; a separate development entrypoint would keep the operator-facing schema honest.
- **Whether the launcher should refuse to launch under-specified.** A repo that looks like a workspace, a plan whose contract names a runner the worktree will not have — both are checkable before spending anything. Refusing is loud and blocks on false positives; asking interactively is friendlier but breaks scripted launches.
- **Whether `--attach` should exist at all.** It is documented with a warning that Ctrl-C cancels the run rather than detaching — a flag whose own help text explains how it will hurt you.
