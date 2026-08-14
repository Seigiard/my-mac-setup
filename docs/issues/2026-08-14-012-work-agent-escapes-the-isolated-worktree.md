---
title: The work agent is handed an absolute plan path into the main checkout and writes its changes there
type: bug
date: 2026-08-14
status: open
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
