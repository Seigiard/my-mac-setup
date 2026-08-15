---
title: Completion is not a verdict — render the decision where the operator acts
date: 2026-08-15
category: design-patterns
module: se-pipeline
problem_type: design_pattern
component: development_workflow
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
  - documentation
applies_when:
  - "A machine step both completes and decides, and a human is asked to respond to the decision"
  - "A generic runner reports node completion but the verdict lives one layer up"
  - "Wiring an approval or pause node whose request is persisted but never rendered"
  - "Naming the human's available actions (approve/deny/retry/waive) in a UI, a CLI, or docs"
  - "Approve at a red gate costs money or means something other than continue"
  - "A workflow re-renders on every frame and a human-facing line must fire once per execution"
symptoms:
  - "A failed gate and a green gate print the identical completion mark, so the log reads as all-green"
  - "An approval prompt names the node but not what is being decided or why"
  - "Operator approved a red gate believing it meant continue; it meant retry the stage and pay again"
  - "Reading a gate's real verdict required querying the database directly, every time"
  - "CLI help described an action's effect incorrectly, teaching the wrong mental model"
tags:
  - human-in-the-loop
  - approval-gate
  - observability
  - se-pipeline
  - smithers
  - decision-surface
  - false-green
  - cli-ux
---

# Completion is not a verdict — render the decision where the operator acts

## Context

`se-pipeline` is a durable multi-stage workflow on the Smithers engine, driven by the bash launcher `se` (source: `home/private_dot_claude/dot_smithers/`, deployed to `~/.claude/.smithers/`). Each stage ends in a *gate*: a pure predicate returning `green`, `failed`, or `degraded`. A non-green gate parks the run at an approval pause and waits for a human.

The engine prints `✓ <nodeId>` for every node that finished without throwing. A gate node that decided `failed` also finished without throwing, so it got the identical mark. The verdict was never printed. The approval that followed printed only the node id.

Verbatim, `run-1786718288581` (2026-08-14), both work gates red:

```
[00:09:01] ✓ work-extra (attempt 1)
[00:09:01] → gate-work-extra (attempt 1, iteration 0)
[00:09:06] ✓ gate-work-extra (attempt 1)
[00:09:06] ⏸ Approval requested: approve-work-2
[00:09:06] ⏸ approve-work-2 waiting for approval
[00:10:36] ✓ Approved: approve-work-2
```

The durable verdict for those same nodes:

```
$ sqlite3 ~/.claude/.smithers/smithers.db \
  "SELECT node_id, state, reasons FROM gate_verdict WHERE run_id='run-1786718288581';"
gate-work        | failed | validate-cmd exited with code 1; …Cannot find module '…/@membranehq/sdk/dist/index.node.js'
gate-work-extra  | failed | (same)
```

Nothing was missing from the data. `stageBlock` already built both a title and a summary into the approval request (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx:369-372`), and the engine already persisted them in `_smithers_approvals.request_json`. No surface rendered them.

The operator read the check marks as green stages and approved twice. At a failed work gate, approve means *retry this stage and pay for another agent leg* — not "continue". After the second failure the run stopped with verdict `stopped-after-second-failure:work`; simplify and verify-code never ran. Cost: $1.83 and two work legs. The operator's written summary said those stages were green — a correct reading of the only surface they had.

A compounding factor: the CLI help read `approve <runId>  approve a paused run (continue past the gate)`. False at a red gate. The docs taught the wrong model of the same action.

**This was the second occurrence, at a third of the previous cost (session history).** Two days earlier, `run-1786544239413` parked on a red `gate-work`; approve produced a `work-extra` node, that attempt went red too, and the run terminated `stopped-after-second-failure:work` having burned $5.43 and 7.7M tokens with nothing past work. Both times the gate was red for reasons *outside the diff* — a bare worktree missing built workspace dists, and a test-race flake — so the operator's instinct that "the gate lied, and not about the code" was right about the cause and wrong about the remedy. The semantics of approve-on-red were therefore already known and named; they lived in one session's narrative and never on the operator's screen.

**Reading the real verdict always meant going around the log into SQLite (session history).** Across three days of sessions, every time a run parked, the reasons were pulled with raw queries against `_smithers_approvals` and `gate_verdict`, because `se list`, `se logs`, and `se show --json` yielded only `status: waiting-approval`. That repetition is the evidence: the data was computed, persisted, and reachable the whole time, and every consumer had to bypass the product to get it. One session had to open with the sentence "the run is parked, not failed", because `waiting-approval` reads identically for a green checkpoint and a red gate.

Two approaches were considered and rejected:

- **Change or suppress the engine's check mark.** It belongs to the engine and honestly means "the node finished". Rewriting it from workflow code would hide a true signal to compensate for a missing one.
- **Log the verdict at render time.** The workflow re-renders on every frame (24 frames on this run), so a render-time log prints the same block dozens of times. The verdict must be emitted inside the gate's `Task` body, which executes exactly once per gate execution.

Fix shipped in commit `393aaed` ("Print the gate verdict where the operator decides").

## Guidance

**1. Completion and verdict are two different facts. The layer that owns the decision renders the decision.**
A generic runner can only report that a step finished; it does not know that this step's return value is a red verdict. Do not ask it to. The workflow layer that computed the verdict emits it, and the runner's completion mark is left untouched (`gate-announce.ts:1-6` records exactly this reasoning). The announcement is a pure string builder — `gateAnnouncement(stage, state, reasons, next)` (`home/private_dot_claude/dot_smithers/workflows/lib/gate-announce.ts:21`) — so the wording is testable without executing a run.

**2. Emit once per decision, not once per render.** The call sits inside the gate `Task` body, next to the verdict computation (`se-pipeline.tsx:345-347`, called at `:355` for the first gate and `:399` for the extra-attempt gate). In any declarative or re-rendering runtime, side-effecting output belongs where execution happens exactly once; a log line in the render path becomes noise that trains the operator to skip it.

**3. Say what each available response will cause — in the words of its consequence, not its label.** This was the larger half of the trap. The three offers are a closed type, and each carries its own sentence (`gate-announce.ts:8,15-19`):

```ts
export type GateNext = "waive" | "extra-attempt" | "abort-only";

const NEXT_ACTION: Record<GateNext, string> = {
  waive: "approve = WAIVE this gate and CONTINUE the pipeline | deny = abort the run",
  "extra-attempt": "approve = ONE more attempt of this stage (it will be re-run and re-paid) | deny = abort the run",
  "abort-only": "approve = STOP the run and write a report (no further stages) | deny = fail the run",
};
```

An "approve" that silently means "retry and re-pay" — or, at the second failure, "stop the run" — is a trap no amount of correct persistence fixes. Typing the offer set also means a new gate cannot be added without choosing which sentence the human will read.

This generalized past the pipeline on independent evidence. A later change (`6b8ea7a`) mined 2532 sessions, found 35 requests where a reader could not answer a decision question, and traced the common cause to the same defect in a different costume: the decision buried at the bottom of a report, compressed into session-local labels, or several asked at once. It promoted a four-part brief — the thing in plain words, the decision, the options *with their consequences*, a recommendation — into the shared writing style and duplicated it at each point of failure, the pipeline's approval gate among them. One decision per turn; report turns carry no questions. The rule below is therefore not pipeline-specific: it was rediscovered from a corpus and applied to every decision surface in the toolchain.

The label was misleading for a structural reason worth naming: every downstream stage is *constructed* inside `if (work.status === "green")` (`se-pipeline.tsx:690`), so when work is not green those nodes never exist and there is nothing for the engine to continue into. The only continuation available at a red work gate is a re-run of the stage. "Approve" could not have meant continue — the wording promised something the architecture could not do.

**4. Persisting the decision durably is not the same as showing it — and every surface the human might use must show it.** The request had been in the database since the first pause. Three surfaces now read `_smithers_approvals` where `status='pending'` (`home/private_dot_claude/dot_smithers/bin/executable_se:138-159`):

- `se show <runId>` — a `DECISION REQUIRED` block in human output (`:504`) and a `pendingApprovals` array in `--json` (`:477-486`), so the human and the unattended caller read the same rows.
- `se approve` / `se deny` — both route through `cmd_decide` (`:208`), which prints the pending request **before** recording the decision (`:222`). Deciding blind now requires ignoring text already on screen.

The renderer is best-effort and never fatal: a missing `sqlite3` or `jq`, a bad run id, or an unparseable `request_json` degrade to no block or `(request unreadable)` (`:140-142,157`), because a broken decision *renderer* must not break the decision *path*.

**5. An absent reason must not read as an absent problem.** Empty reasons render `(no reason recorded — this is itself a defect, please report it)` (`gate-announce.ts:38`). Reasons arrive joined with `"; "`, and one of them carries a multi-line command tail; the tail stays attached to its own reason as indented continuation lines rather than becoming fake extra `why:` entries (`gate-announce.ts:24-28,34-43`). Blank space and mis-attributed detail are both ways a rendered verdict lies.

**6. The wording of the action is part of the decision surface — so pin it with a test.** The false help line was rewritten to state what approve actually does (`executable_se:77-88`), and a bats test asserts the old promise cannot return: `refute_output --partial 'approve a paused run (continue past the gate)'` (`tests/scripts.bats:1564-1570`). Prose that describes an affordance is as load-bearing as the affordance; without a test, it drifts back. This is the second instance of misleading CLI help in the same tool — a `se resume` hint once named a flag that did not exist (`docs/issues/2026-08-14-006-se-resume-hint-names-a-flag-that-does-not-exist.md`) — which is what makes it a pattern rather than a slip.

**7. A decision that is recorded but drives nothing is still not a decision.** Adjacent, same theme, shipped just after in `9350484`: the owner process exits when a run parks, so a recorded approval moved nothing until someone ran `se resume` — measured on the same run, approved 16:42:24, no progress until a manual resume at 16:44:47 (`executable_se:189-206`). `se approve` and `se deny` now resume the run themselves, and only when no live process owns it (`:175-187`), because two engines on one run corrupt its state. The decision surface ends where the decision takes effect, not where it is stored.

## Why This Matters

A human gate exists to put judgment in the loop. If the only thing the human sees is "the step finished", the gate has been converted into a rubber stamp with extra latency: the operator supplies a signature and none of the judgment the design paid for.

The cost is concrete and asymmetric. On `run-1786718288581` two approvals bought two failed work legs at $1.83 and ended the run before simplify and verify-code ever executed — while the operator believed they were confirming green stages and wrote that down. The failure is invisible from inside: nothing errored, no alert fired, and the operator's report of the run was wrong in a way only the database could contradict. That is the signature of a missing decision surface rather than a missing feature.

It also does not announce itself as a recurring bug. The same trap fired two days earlier for $5.43 and was read as a validate-command problem both times, because the surface that would have shown the pattern was the very thing missing. A defect in the decision surface hides its own repetitions.

The generalizable claim: **in any system where a machine step both completes and decides, completion and verdict are two different facts.** A runner that reports only completion renders a red decision identically to a green one. The layer that owns the decision must render the decision — its verdict, its reasons, and what each available human response will actually cause — at the moment and on the surface where the human acts. Storing it durably is not showing it, and a label like "approve" is not a description of an effect.

## When to Apply

- Any step that returns a *judgment* (pass/fail/degraded, score, policy verdict) while running inside a generic executor that reports only success or failure of execution — CI job matrices, workflow engines, batch schedulers, agent orchestrators.
- Designing a manual approval: a deploy gate, a release sign-off, a "confirm destructive migration" prompt. Ask what the approver sees at the instant they act, not what the system knows.
- Whenever the same word means different things in different states. "Approve" at gate attempt 1 (retry, re-pay), at a waivable gate (skip and continue), and at attempt 2 (stop with a report) are three different actions wearing one label — name the effect, per state.
- When a decision record is persisted (DB row, audit table, webhook payload) and you are about to call the feature done. Enumerate the surfaces the human actually uses — log stream, CLI status, dashboard, notification, the decision command itself — and check each renders it.
- When the people operating a system routinely query its database to answer a question the product should answer. That habit is a specification of the missing surface, and it hides the defect by making it survivable.
- When a re-rendering or reconciling runtime (React-like workflows, Kubernetes controllers, retry loops) must emit a human-facing message: place it on the once-per-execution path, or it becomes ignorable noise.
- When you write help text, tooltips, or button labels for an irreversible or billable action — and add a test that pins the wording, because a wrong description is a defect with no stack trace.

## Examples

**The trap, verbatim.** Log shows `✓ gate-work-extra` then `⏸ Approval requested: approve-work-2`; the durable row for that node says `failed | validate-cmd exited with code 1; …`. Two check marks, no reason, two approvals — full narrative in `docs/issues/2026-08-14-016-run-log-marks-a-failed-gate-as-passed.md` (status: done).

**The fix, rendered from that same persisted verdict:**

```
────────────────────────────────────────────────────────────────────────
GATE work: FAILED — the run is about to pause for your decision
  why: validate-cmd exited with code 1
  why: validate-cmd output tail: atterns.
       No files found matching the given patterns.
        FAIL  workload-comparison/result.test.ts
       Error: Cannot find module '…/@membranehq/sdk/dist/index.node.js'
  approve = ONE more attempt of this stage (it will be re-run and re-paid) | deny = abort the run
────────────────────────────────────────────────────────────────────────
```

A green gate stays one quiet line — `GATE work: GREEN` (`gate-announce.ts:22`) — so the reader can distinguish a gate that announced itself from one that never ran, without a wall of text on the happy path.

**Mutation check (the proof the fix does something).** The same fixture run against the OLD deployed `se show` prints ten dashes and no decision block; against the new one it prints the `DECISION REQUIRED` block with the request's title and reasons. Fixture and assertions: `tests/scripts.bats:1457-1470` (block present), `:1472-1483` (approve echoes "approve stops the run WITH a report" before recording), `:1485-1496` (no block when nothing is pending).

**Wording under test.** `gate-announce.test.ts` (9 tests) asserts the exact failure modes of the incident rather than the format: the state appears as a word not a mark (`:9-15`), the reason reaches the screen (`:17-20`), approve is named as a stage retry (`:22-29`), the multi-line tail stays a continuation of its own reason (`:42-52`), and an empty reason does not pass for "no problem" (`:54-57`).

**Verification of the shipped change:** commit `393aaed` added 9 tests to `home/private_dot_claude/dot_smithers/workflows/lib/gate-announce.test.ts` and 4 to `tests/scripts.bats`, with the whole suite green and shellcheck clean at that point. Absolute suite totals are deliberately not quoted here — they moved twice the same day and would read as false to the next person who checks. Not covered: no live pipeline run has printed the announcement yet — it is proven by rendering real persisted verdicts through the same function the pipeline calls.

**Docs as a surface.** The runbook now names the wrong reading explicitly (`docs/se-pipeline.md`, "галочка в логе — не вердикт", with this run as the example), and the `se-work` skill tells an agent never to read `se logs` check marks as verdicts (`home/private_dot_claude/skills/se-work/SKILL.md`) — it previously told the agent to gather context from those logs with no such warning.

## What this does not fix

A rendered verdict is only as honest as the verdict itself. A gate that goes **green** having verified nothing still misleads, and the announcement will faithfully print `GATE work: GREEN` for it — see `docs/issues/2026-08-14-018-validate-segment-can-pass-covering-nothing.md` (status: open), where a validate segment matching zero files exits 0. Rendering the decision fixes the surface, not the predicate behind it.

Informed approval is also only half of the cost control. The other half is a spend ceiling, which `se pipeline` does not have — `docs/issues/2026-08-14-015-run-budgets.md` (status: open).

## Related

- `docs/issues/2026-08-14-016-run-log-marks-a-failed-gate-as-passed.md` — the incident, the rejected options, and the resolution (status: done).
- `docs/issues/2026-08-14-017-run-stalls-after-every-approval.md` — the sibling defect on the same CLI path: the decision was recorded and nothing drove the run (status: done).
- `docs/issues/2026-08-14-019-worktree-missing-built-dists-is-not-detected.md` — why that gate was legitimately red; only its presentation failed (status: done).
- `docs/issues/2026-08-14-020-pipeline-launch-surface.md` — the same honesty rule one stage earlier, at launch (status: open).
- `docs/se-pipeline.md` — runbook: check-mark-is-not-a-verdict, and the per-gate table of what `approve` means at each gate.
- `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md` — sibling pattern: a step that dies quietly must not read as a clean pass. Same family, one layer earlier — there the *machine* misread the evidence, here the *human* did.
- `docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md` — fail-closed at a different boundary; a scanner crash is never a clean pass.
