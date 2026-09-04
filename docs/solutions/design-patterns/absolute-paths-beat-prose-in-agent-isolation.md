---
title: A path in the prompt outranks prose about the sandbox
date: 2026-08-15
category: design-patterns
module: agent-platform
problem_type: design_pattern
component: development_workflow
severity: high
root_cause: scope_issue
resolution_type: code_fix
related_components:
  - tooling
applies_when:
  - "Dispatching a coding agent into an isolated worktree, container, or sandbox it is expected to stay inside"
  - "Handing an agent a spec, plan, or fixture that must be frozen for the run"
  - "Choosing where a run-local copy of an input lives relative to the sandbox"
  - "Designing a proof-of-work or diff invariant that decides whether an agent leg produced anything"
  - "Deciding whether a boundary check with a plausible benign cause should block a run or only annotate it"
symptoms:
  - "Work gate reports no content change while the real edits sit uncommitted in the operator's main checkout"
  - "Run branch stays at the base commit after a full, expensive agent leg"
  - "The prompt says the cwd is an isolated worktree and hands over an absolute path outside it"
  - "The same prompt shape ships in two components before either is caught"
tags:
  - se-pipeline
  - se-flow
  - agent-sandboxing
  - prompt-design
  - worktree-isolation
  - proof-of-work
  - smithers
---

# A path in the prompt outranks prose about the sandbox

Paths shortened to `lib/…`, `se-pipeline.tsx` or `se-flow.tsx` are relative to
`home/private_dot_claude/dot_smithers/workflows/`; every other path is from the repo root.

## Context

> **Where this evidence lives now.** The Smithers runtime and both `se-pipeline` executors were
> removed on 2026-09-01 (`docs/decisions/0001-se-pipeline-architecture-redirection.md`), so every
> `dot_smithers/**` path cited below is readable only in git history. The transferable rule outlived the incident: it is why child-agent coordinates are exported into the pane environment (`home/dot_local/lib/herdr-child-launch.sh`) rather than only described in a prompt, and why `se-doc-review/SKILL.md:36-41` stages a frozen `DOC_COPY` outside the working tree.

The se-pipeline stages an isolated `git worktree` on a run branch and dispatches the work agent with that worktree as its cwd. The prompt said so in plain words — "your cwd is an ISOLATED git worktree of the target repository, already on the run branch … do NOT create worktrees" (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx:238`) — and in the same prompt handed the agent an absolute path to the plan file in the operator's **main checkout**, by design: `inputSchema.planPath` was "read from the launcher, never from the worktree (KTD11)" so a plan edited mid-run could not change the contract the run was gated on.

On `run-1786717826270` the agent wrote both changed files into that main checkout (`/Users/andrew.b/Projects/platform-2`) on `main`. The run branch stayed empty at the base commit. Those two facts are what the run recorded. The mechanism behind them — the agent resolving every repository path against the plan's repository rather than against its cwd — was inferred from the prompt at the time and never instrumented (`2026-08-14-012` says "the likely mechanism"). It is the only reading consistent with where the files landed, and both fixes are built on it, but it is an inference.

What caught it was not a guard against escape — there was none — but an unrelated proof-of-work invariant. `workGate` compares the worktree's tree object against the base commit's and fails a leg that produced no content (`home/private_dot_claude/dot_smithers/workflows/lib/gates.ts:313-314`, via `treeHash` in `lib/staging.ts:378`). The run parked with `worktree tree hash equals base — no content change, agent produced no work (KTD14)`: a message that names the symptom and blames the agent. The operator pays for a full agent leg, gets a red gate, and finds their real changes uncommitted on `main` — the one place the pipeline promises not to touch (`2026-08-14-012`).

The same one-line prompt shape existed in a second interpreter in the same repo: se-flow's `work` block built `Execute the plan at ${i.planPath} …` from an operator-supplied spec field (`2026-08-15-002`). Nothing about the mechanism was specific to se-pipeline; both were closed in commits `1c3c164` and `89ed25a`.

## Guidance

1. **A prompt must not name a path outside the sandbox at all.** Not "name it and warn about it" — not name it. An agent resolves relative work against the most concrete anchor it was given, and a repository-shaped absolute path is more concrete than any sentence about boundaries. Any prose that competes with a path in the same prompt is a prose-versus-path contest you will lose the first time it matters.

2. **When the agent must read something that lives outside, freeze a run-local copy and hand it that.** `stageRunPlan(planPath, branch, expectedPlanHash)` (`lib/staging.ts:147`) copies the plan once at staging and returns the copy's path; the pipeline calls it in the `staging` task (`se-pipeline.tsx:545`) and the work prompt is handed `staged.planCopyPath ?? gate0.planPath` (`se-pipeline.tsx:702`, the fallback only so a run resumed from a pre-copy row still runs). Freezing serves the original intent better than the live path did: the copy cannot be edited mid-run at all. It is verified before it is written — the plan on disk is re-hashed against the hash the run recorded at its freeze point and a mismatch refuses rather than silently freezing a different spec (`lib/staging.ts:159-164`, using the single `planContentHash` in `lib/gates.ts:78` that gate 0, the KTD7 re-check, and staging all share). Re-staging is idempotent: an identical copy is left alone, a divergent one is rewritten (`lib/staging.ts:172-173`).

3. **The copy goes BESIDE the sandbox, never inside it.** This is where a re-implementer goes wrong, and it has two independent reasons. The pipeline commits the agent's work itself with `git add -A` (`commitWorkGuarded`, `lib/staging.ts:329-333`), so a copy inside the worktree would be committed onto the run branch. Worse, it would make `treeHash(worktree) !== baseTree` true even for a leg that changed nothing — destroying the exact proof-of-work invariant that is the only thing that caught this bug. The copy lands in a sibling directory `<worktree>-plan/` keeping the original basename (`lib/staging.ts:167-171`).

4. **Keep the prose, but make it describe something true.** The prompt still explains the file's nature — "a FROZEN COPY, staged for this run only … it lives OUTSIDE every repository on purpose … EVERY repository path you resolve, read, or write belongs to your cwd" (`se-pipeline.tsx:236`). That sentence is now a fact about the path in the same prompt, not an instruction competing with one. In se-flow the provenance half is appended by the interpreter (`frozenPlanNote`, `lib/flow-run.ts:144`, applied at `se-flow.tsx:561-562`) rather than written into the pure `buildPrompt`, because only the interpreter knows whether this render actually froze a copy — a prompt must not claim a provenance that is not true for it.

5. **Add the diagnosis the failing invariant could not give, and keep it advisory.** Staging records a digest of `git status --porcelain` in the target repo (`repoDirtyDigest`, `lib/staging.ts:221`; recorded at `se-pipeline.tsx:548`); the work gate re-reads it and `mainCheckoutEscapeReason` (`lib/gates.ts:341`) names the escape and points at `git -C <repo> status`. The gate appends the reason and never touches the verdict (`se-pipeline.tsx:684-685`). The economics decide this: an operator editing their own checkout during a multi-hour run is ordinary, so the check has a real false-positive rate, and a red gate on a false positive costs a full extra agent leg. Diagnosis is cheap to be wrong about; a verdict is not.

6. **Delete the frozen copy with the sandbox.** It holds the source document's full text outside any repository, so it is removed on the green path and on the sweep path, not left in `/tmp` for the OS to collect whenever it feels like it — `cleanupSnapshot` removes the sibling directory even when the worktree removal itself failed (`lib/staging.ts:304-322`), and `sweepOrphans` does the same for a terminal run (`lib/staging.ts:292`).

## Why This Matters

- The failure is expensive and mislabelled. The invariant that caught it can only report "the agent produced nothing", so the operator's first hypothesis is a bad agent leg, not an escape — and the work they are missing is sitting dirty in their own checkout, where a later `git checkout` or a stash can lose it.
- Two components in one system had the same defect from the same prompt shape, filed a day apart. That is the signature of a design rule, not of two mistakes: any prompt that names an outside path reproduces it.
- Removing the pointer costs one copy and one hash — per run in the pipeline, per render in se-flow, which re-verifies each copy against the recorded hash every time it renders. It buys back the isolation guarantee the whole staging apparatus — run branch, repo lock, worktree, proof of work — exists to provide.
- The invariant that caught this is worth protecting on purpose. Putting the frozen copy inside the worktree would have been the obvious placement and would have silently converted the tree-hash proof into a constant `true`, so this class of bug would never be caught again.

## When to Apply

- Any time an agent is dispatched into an isolated cwd (worktree, container, scratch checkout) and must read a spec, plan, fixture, or dataset that lives elsewhere: copy it in-run and hand over the copy's path.
- When the copy would be swept up by the harness's own `git add -A`, a build, or a diff-based invariant: place it beside the sandbox, not inside, and check what your proof-of-work compares before choosing the location.
- When adding a second interpreter, block, or entry point that dispatches the same kind of agent: grep for every prompt builder that interpolates a path, not just the one you are editing.
- When a boundary check has a plausible benign cause (a human working in the same repo): make it advisory and let the exit-code/invariant layer stay the only thing that changes verdicts.

## Examples

**Before (both components).** `se-pipeline.tsx` invoked `ce-work` with the launcher's absolute plan path, then explained the worktree in the next paragraph. `lib/blocks/index.ts` did it in one line: `Execute the plan at ${i.planPath} headless via ce-work mode:return-to-caller.` with an operator-supplied `planPath` from the flow spec.

**After.** The pipeline freezes at staging (`se-pipeline.tsx:516-548`) and prompts against the copy (`:702`). se-flow hashes at staging — it has no plan-hash gate 0, so the staging moment *is* its freeze point — persists `{blockId, planPath, planHash, copyPath}` in its durable `staging` row (`se-flow.tsx:126`, `:223-225`), re-verifies every copy on every render through `resolveStagedPlans` (`lib/staging.ts:201`, called at `se-flow.tsx:265`), and substitutes the copy into the block input at the one seam that knows both paths (`withStagedPlanPath`, `lib/flow-run.ts:134`, applied at `se-flow.tsx:561`). A refusal never falls back to the recorded copy: the copy can be intact while the spec behind it moved. The block's own prompt now carries only the cwd rule, no outside path (`lib/blocks/index.ts:238-246`). The runbook states the placement and its reason in the same breath, for the pipeline (`docs/se-pipeline.md:227-233`) and for se-flow (`:286-295`).

**Still not solved — nothing confines the agent to its cwd.** The third option in the issue ("confine the agent to its cwd rather than relying on prompt prose") was not taken: the agent CLI offers no filesystem boundary to lean on. The fix removes the pointer instead of building a fence, so an agent that decides to write outside its worktree for any other reason still can, and only the advisory digest will hint at it. Treat rule 1 as mitigation, not enforcement.

**Open gap in se-flow.** se-flow has no escape diagnosis at all: its proof-of-work comparison reports only "no content change" (`lib/blocks/index.ts:98-102`, over the trees `commitWorkEffect` computes at `lib/block-effects.ts:113-117`). The digest check was deliberately not ported, because se-flow can legitimately run with `worktreePath === repoPath` (no workspace needed), where a dirty main checkout is expected and the comparison would be actively wrong without a suppression signal. Tracked as `2026-08-15-005` (status: open).

**Verification status.** The pipeline fix is covered by `lib/staging.test.ts` (copy placement outside the worktree, the explicit regression guard that `commitWorkGuarded` after staging commits nothing and leaves the tree hash at base, hash-mismatch refusal, idempotent re-staging) and `lib/gates.test.ts` (the escape reason only ever adds to a verdict). The se-flow half is proven by unit tests only — editing the interpreter's module graph is forbidden while a run is live or parked (KTD1), so a live re-run is the operator's call.

## Related

- `2026-08-14-012` — the original incident and its resolution (commit `1c3c164`).
- `2026-08-15-002` — the same doorway in se-flow (commit `89ed25a`).
- `2026-08-15-005` — open: no escape diagnosis on the flow path.
- `docs/se-pipeline.md` (removed 2026-09-01 with the Smithers runtime; git history only) — runbook: frozen plan copy beside the worktree, per-render re-verification, substitution in the interpreter.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-14-012`, `2026-08-15-002`, `2026-08-15-005`.
  Those files were removed in the closed-issue cleanup; the evidence they carried is reproduced inline above.
