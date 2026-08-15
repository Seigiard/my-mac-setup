---
title: The work agent is handed an absolute plan path into the main checkout and writes its changes there
type: bug
date: 2026-08-14
status: done
closed: 2026-08-15
---

# The work agent escapes the isolated worktree

## Why this exists

The pipeline stages an isolated `git worktree` on a run branch and runs the work agent with that worktree as its cwd. On `run-1786717826270` the agent instead wrote both changed files into the operator's main checkout at `/Users/andrew.b/Projects/platform-2`, on `main`. The run's worktree and its branch `se/2026-08-14-001-fix-prepush-format-ignore-17826270` stayed empty at the base commit.

The likely mechanism is in the prompt. `workPrompt` (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx:205`) tells the agent:

```
Invoke the skill compound-engineering:ce-work with args "mode:return-to-caller ${planPath}".
```

`planPath` is absolute and points into the **main checkout**, by design — `inputSchema` documents it as "read from the launcher, not the worktree (KTD11)", so that a plan edited mid-run cannot change the contract. The agent opens that file, and every path it then resolves relative to the plan's own repository root lands outside the worktree. The prompt's later sentence ("your cwd is an ISOLATED git worktree … do NOT create worktrees") is prose competing with a concrete absolute path, and the path won.

Nothing in the agent's environment prevents the write: the work leg is not confined to its cwd.

**The pipeline caught it.** `gate-work` failed with `worktree tree hash equals base — no content change, agent produced no work (KTD14)` and the run parked at `approve-work-1`. The KTD14 tree-hash invariant is what stands between this defect and a run that ships an empty branch after two review legs find nothing to review. The invariant works; the defect it is catching should not exist.

The damage is not silent corruption, it is wasted work: the operator pays for a full work leg, gets a red gate, and finds the real changes uncommitted on `main` in their own checkout — the one place the pipeline promises not to touch.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — `workPrompt` and the `planPath` it embeds.
- Whatever confinement the work agent runs under (`makeWorkAgent`, `home/private_dot_claude/dot_smithers/workflows/lib/agents.ts`).

## Open decisions

- **Copy the plan into the worktree and pass the copy's path.** This removes the doorway entirely: every path the agent sees is inside the worktree. It appears to conflict with KTD11 ("read from the launcher"), but the intent of KTD11 is that the plan's *content* is frozen at gate 0, and a copy taken at staging time satisfies that better than a live path does — the copy cannot be edited mid-run at all.
- **Confine the agent to its cwd** rather than relying on prompt prose. If the agent CLI supports a filesystem boundary, that is the durable fix; prose instructions lose to a concrete path every time.
- **Fail loudly at the gate with the right diagnosis.** Today the operator reads "no content change, agent produced no work", which describes the symptom and points at the agent. Detecting that the main checkout became dirty during the work stage would name the real cause. Cheap to check: the pipeline knows both paths.

## Resolution

The doorway is closed: the work agent is no longer given a path into the launcher's checkout, and the gate now names the escape when it happens anyway. The third option (confining the agent to its cwd) was not taken — the agent CLI has no filesystem boundary to lean on, and with no launcher path in the prompt there is nothing pointing outward.

- `home/private_dot_claude/dot_smithers/workflows/lib/staging.ts` — new `stageRunPlan(planPath, branch, expectedPlanHash, opts?)` copies the plan to `<worktreeBaseDir>/<branch-with-slashes-dashed>-plan/<original-basename>` and returns that path. The copy sits BESIDE the worktree, never inside it: `commitWorkGuarded`'s `git add -A` would otherwise commit it and make `treeHash(worktree) !== baseTree` true for a leg that did nothing, destroying the KTD14 invariant that caught this bug. The plan on disk is re-hashed against gate 0's hash before anything is written, and re-staging on resume is idempotent (identical copy left alone, divergent copy overwritten). Also new: `repoDirtyDigest(repo)`, a digest of `git status --porcelain` in the target repo.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `planContentHash` extracted from `planGate` so gate 0, the KTD7 re-hash, and the staged copy all agree on one hash. New pure `mainCheckoutEscapeReason(repoDir, stagedDigest, currentDigest)` returns the diagnosis string, or undefined when nothing moved or the staged digest is absent (resume from a pre-change row).
- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — the `staging` output gained nullish `planCopyPath` and `repoDirtyDigest` (nullish so rows persisted before this change still resume). Staging freezes the plan copy and records the checkout digest; `workPrompt` is handed `staged.planCopyPath ?? gate0.planPath` and now tells the agent the file is a frozen copy outside every repository, so every repository path it resolves belongs to its cwd. `gate0.planPath` remains the authority for the KTD7 re-hash in `workGateFn` — that check exists to catch an operator editing the real plan mid-run. `workGateFn` appends the escape diagnosis and never changes the gate state: an operator editing their own checkout during a multi-hour run is ordinary, and a red gate on that costs a full extra work leg.
- Tests: `workflows/lib/staging.test.ts` covers the copy's placement outside the worktree, the explicit KTD14 regression guard (`commitWorkGuarded` after staging commits nothing and leaves the tree hash at base), hash-mismatch refusal, unreadable plan, idempotent re-staging, and the `worktreeBaseDir` override; `workflows/lib/gates.test.ts` covers the escape reason and proves it only adds to a verdict.

The frozen copy is removed with the worktree it belongs to: `cleanupSnapshot` deletes the sibling `<worktree>-plan` directory on a green verdict, and `sweepOrphans` does the same for a terminal run's worktree. The copy holds the plan's full text outside any repository, so leaving it in `/tmp` for the OS to collect was not good enough.

The same doorway on the se-flow block path (`workflows/lib/blocks/index.ts:215`) was left untouched and filed as `docs/issues/2026-08-15-002-se-flow-work-block-hands-the-agent-a-launcher-plan-path.md`.
