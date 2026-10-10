---
name: pf-build
description: Implement an approved contract spec in real code by running each sub-task through the tdd chain, then prove it live with a demo. Third step of the /pf-research -> /pf-spec -> /pf-build cycle. Use when the user says "pf-build <epic-or-topic>" or wants an approved contract spec implemented.
argument-hint: "<epic-or-topic>"
---

# /pf-build - implement the contract spec and prove it live

Implement the open **epic PR**'s contract deltas in real code. Slice the work into local sub-task files, run every sub-task through the `tdd` chain, validate and open each sub-task PR, and merge each implementation PR into the epic branch. The orchestrator pushes and opens a sub-task PR only after chain validation. The build ends with a **demo**: a walkthrough of the new functionality in the real product, validated live, with a discrepancy report against the contract spec. The user reviews and merges the one big PR into main. Third step of the `/pf-research` -> `/pf-spec` -> `/pf-build` cycle. Read `~/.claude/shared/pf-cycle.md` first; for screenshots and narrative pages also read `~/.claude/shared/pf-cycle-narratives.md`. You are the orchestrator and the only human-facing party. Task management stays in the artifact directory's `tasks/` files.

Invoked as `/pf-build <epic-or-topic>` (the artifact directory's id: a topic slug, or a Linear identifier like PRD-1234 when an epic exists). If none is given, use the one from the current conversation.

**Fresh context.** When this conversation already ran `/pf-research` or `/pf-spec`, say in one line that the artifact directory and the epic PR carry everything and `/clear` then `/pf-build <id>` runs leaner; then continue unless the user clears.

## Two ways to build

**Epic-PR-based (the default, everything below).** The full cycle: an open epic PR is the target, children merge into its branch, local task files track the sub-tasks, and the child-CI caveat, watcher, and heartbeat apply.

**Direct build (no epic PR)** - when the user skips the spec step, or the change is small and self-contained enough that the ceremony is pure overhead. Follow `references/direct-build.md` instead of the sections below.

**No epic PR yet, epic-PR-based mode? Spec first, in this same run.** Follow `pf-spec` to author the contract deltas and open the epic PR. The user is away, so record judgement calls as assumptions in the status report and continue. Scale the spec to the change. Never invent contract surface.

**Prerequisite - epic PR open.** Once the spec exists, the epic PR must exist and be open with base `main`. If its CI is red, fix it in parallel as an epic-branch ticket through the `tdd` chain. Slicing and dispatching sub-tasks continue while that fix runs. A red epic PR gates merging children, not dispatch. If the branch is behind main, update it and rebuild committed contract artifacts before slicing. Never merge the epic PR itself.

**Prerequisite - opencode ready.** `opencode --version` must run and `opencode models` must list the `openai/` provider. When no chain child can start (see `tdd` -> Dispatch), stop and report; never write the work yourself.

## Autonomy

Run the whole loop autonomously. Never ask, pause, or wait for input. Slicing, dispatching, validating, rebasing, pushing, opening PRs, triaging, merging into the epic branch, and closing tasks are yours. Genuinely user-owned decisions get flagged and routed around as assumptions for final review.

## Step 0 - Slice the work into sub-tasks

Derive implementation work from the contract spec: the epic PR's diff plus the spec narrative's deferred deltas. Author each sub-task as `~/.claude/artifacts/<id>/tasks/<TASK-ID>.md`. The first line is `Status: Ready | In progress | In review | Blocked | Done`, updated as work proceeds. Task bodies are written for a zero-context reader.

Each sub-task carries:

- **Goal** - one sentence describing what becomes true.
- **Contract deltas** - the contract pieces it fulfills and every deferred artifact delta it must produce.
- **Validation criteria** - numbered outcomes with named, committed, re-runnable checks.
- **Deploy note** - required for a migration or flag.
- **Out of scope** - one line.
- **Dependencies** - sibling tasks it needs.
- **Overlaps** - siblings that touch the same files or shared surfaces.

Keep the fewest reviewable PRs. Slice vertical user-visible increments. The contract spec decides outcomes; task text removes implementation ambiguity.

## Running a sub-task through the chain

For each ready sub-task, in order:

1. Create its worktree and branch from the current epic branch tip:
   ```bash
   git -C <main-checkout> worktree add .claude/worktrees/oc-<TASK-ID> -b oc/<TASK-ID> origin/<epic-branch>
   ```
   Seed what a fresh worktree needs per the repo's `AGENTS.md`. A rare dependency may stack from `oc/<DEP-ID>` instead of waiting for its merge.
2. Call the Skill tool with `tdd` in that worktree as the sub-task's orchestrator. Give it caller run directory `~/.claude/artifacts/<id>/runs/<TASK-ID>/` and build its ticket from `references/chain-ticket.md`.
3. Children commit every test and every line of code only on `oc/<TASK-ID>` inside that worktree. They never push. Models and tiers come from `tdd`'s ladder.
4. When the chain stops because the ladder is exhausted on high, set the task file's Status to `Blocked`. Dependents wait; independent tasks continue. Report the blocker in the next status report at once and keep the loop running.

The chain owns launch, logs, reports, and escalation. The orchestrator never resumes an earlier child session and never writes a fix itself.

### Push and PR after validation

Only after `tdd` step 5 passes for the sub-task and the contract-delta check passes, push `oc/<TASK-ID>` and run `gh pr create --base <epic-branch> --head oc/<TASK-ID>`. Follow `references/chain-ticket.md` -> PR. A PR is never opened earlier, so no PR carries a lock commit without its code.

## Scheduling and dispatch throttle

Run at most 2 chain children at once across all sub-tasks. The cap counts running children, not sub-tasks or chains. A chain between phases or in validation holds no slot. Do not expand the cap. If a dispatch reports HTTP 429, quota, or rate-limit errors, PAUSE dispatching and resume only after a one-child probe succeeds. Sum each `step_finish` event's `tokens` object from the children's JSONL logs in their run directories when reporting usage.

Dispatch in small waves from the current epic tip. Do not run overlapping tasks in parallel. A dependent task waits for its dependency to merge unless stacking is necessary. Rebase children onto a newly advanced epic tip as described below.

## Findings routing

Every finding on a sub-task, including the orchestrator's contract-delta check and a Greptile P1/P2 on a child PR, gets a verdict as in `code-review` step 4: `test`, `code`, `decision`, or `reject`. Fix it through `tdd` -> `Entering mid-chain` in that sub-task's run directory:

- A behavior gap goes to a fresh test writer, then re-lock, then a fresh implementer.
- A code-only finding goes to a fresh implementer.
- Use one child per role per round. Never resume an earlier child.

After the fix passes step 5 again, push and answer Greptile with a body block and inline comments per the repo's AI PR Review rules. Greptile P1/P2 findings on the big PR use the same route as a ticket on the epic branch.

## Rebases

All rebases are yours. Run clean rebases, then confirm every locked path still matches its `lock_sha` content and the test command is green. On a conflict, abort the rebase and start a fresh medium-tier child to redo the rebase and resolve it, then repeat the lock and green checks as `implement-spec` steps 7-8 require. Alternatively, run the sub-task's chain fresh against the current tip.

## Role boundaries

- Children write every test and every line of code.
- The orchestrator slices, decides, validates, rebases, pushes, opens PRs, triages, and merges into the epic branch.
- Findings follow the routing above.
- The contract spec is binding. An unplanned contract change is a finding or a flag for the user.
- Do not invent scope.

## CI reality of building into a branch

Child PRs based on the epic branch get no CI. Local validation is the gate: full diff review, package typechecks, named tests, and contract artifact checks. The big PR is the real gate for merges. After every child merge, watch its CI to a terminal state. A red big PR blocks further merges, but not slicing, dispatch, or review of other children. Re-run failed infrastructure jobs when appropriate.

## Prerequisite - epic PR open and red fixes

When the big PR is red, run the fix as its own ticket through the `tdd` chain in the epic branch worktree with run directory `~/.claude/artifacts/<id>/runs/epic-fix-<n>/`. Dispatch it in parallel with the first wave. Its timing stays parallel to normal dispatch.

## Watch and heartbeat

Wake sources are each chain child's background-process exit and the PR watcher. Run a full pass immediately, arm the watcher over every active task and the big PR, and maintain the 30-minute heartbeat.

The stuck-detection checklist reads child JSONL log mtimes under `~/.claude/artifacts/<id>/runs/`. A child that is alive but stale for at least 20 minutes is terminated and counted as a failed attempt in that chain under `tdd`'s Escalation ladder. A live chain child or a recorded run directory must exist for every believed-in-flight task. Never take over a child.

## Each pass

1. **Sync.** Re-read the complete `tasks/` directory. Account for every task and find each active task's PR or recorded run directory.
2. **Dispatch.** Start chains for ready tasks under the cap. Mark blocked dependents and continue independent work.
3. **Validate and open the PR.** Per sub-task, run only `tdd` step 5. Run the contract-delta check: artifact diffs match the task file and no unplanned contract change exists. Then push and open the PR under the rule above.
4. **Triage findings.** Apply the findings route above to Greptile and contract-delta findings.
5. **Merge.** Merge a fully validated child PR into the epic branch and watch the big PR CI to a terminal state.
6. **Close out.** Mark the task Done after merge, remove its worktree, and rebase in-flight children onto the new tip.
7. **Report.** Report dispatches, PRs, fixes, merges, blockers, assumptions, and throttle events.

## Epic-branch review

When every child is merged and the big PR is green, call the Skill tool with `code-review` once on the epic branch. Its step 1 chooses the route: prose-only changes use the `writing-for-agents` prose review; any script, template, config, or test uses revmux. Its fixes use their own chain delegation and commit on the epic branch. Wait for the big PR CI to become green again, then run **The demo**.

## The demo - proof it works live

When every child is merged, the big PR is green, and the epic-branch review is finished, prove the change in the real product and publish `references/demo.md`. Refresh the big PR with the demo and discrepancy report.

## End condition

Against a fresh read of `tasks/`, every child is terminal, no child PR or chain child is running, the big PR is green, the demo is published, and the epic-branch review is finished. Remove leftover worktrees, stop the watcher and heartbeat, and present the final report. The user reviews and performs the final merge to main.
