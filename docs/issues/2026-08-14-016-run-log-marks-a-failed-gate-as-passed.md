---
title: "The run log marks a failed gate with a check mark and never prints why the run parked"
short_description: "The run log marks a failed gate with a check mark and never prints why the run parked"
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-15"
---

# The operator is asked to approve a red gate with no reason on screen and a check mark next to it

## Why this exists

`se logs` prints a check mark for every node that finished without throwing. A gate node that evaluated its verdict as **failed** finished without throwing, so it gets the same check mark as a green one. The verdict itself is never printed.

Verbatim from `se logs run-1786718288581`:

```
[00:09:01] ✓ work-extra (attempt 1)
[00:09:01] → gate-work-extra (attempt 1, iteration 0)
[00:09:06] ✓ gate-work-extra (attempt 1)
[00:09:06] ⏸ Approval requested: approve-work-2
[00:09:06] ⏸ approve-work-2 waiting for approval
[00:09:06] ↺ Run status: waiting-approval
[00:10:36] ✓ Approved: approve-work-2
```

That gate's actual verdict, from the durable row:

```
$ sqlite3 ~/.claude/.smithers/smithers.db \
  "SELECT node_id, state, reasons FROM gate_verdict WHERE run_id='run-1786718288581';"
gate-work        | failed | validate-cmd exited with code 1; validate-cmd output tail: …
                             FAIL workload-comparison/result.test.ts
                             Error: Cannot find module '…/engine/api/node_modules/@membranehq/sdk/dist/index.node.js'
gate-work-extra  | failed | (same)
```

Both gates failed. The log shows two check marks and no reason.

The information exists and is well-formed. `stageBlock` builds the approval request with a title that states the verdict and a summary that carries the reasons (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`):

```tsx
request={{
  title: `${name} gate is ${v1.state} — ${waive1 ? "approve to WAIVE and continue" : "approve ONE extra attempt"}; deny aborts the run`,
  summary: v1.reasons,
}}
```

The log stream prints neither the title nor the summary — only `Approval requested: approve-work-2`. So the operator sees a check mark, a request with no subject, and a prompt to approve.

**The observed consequence.** On `run-1786718288581` the operator read the check marks as green stages and approved twice, believing each approval meant "continue". Each approval actually meant "retry the failed work stage". After the second failure the run stopped with `stopped-after-second-failure:work`; `simplify` and `verify-code` never ran. The operator only learned the verdict from the final summary, after $1.83 and two work legs. The operator's own words for the earlier state of the run — "стадии work, gate-work, approve-work-1, work-extra-prep, work-extra, gate-work-extra — все зелёные" — were a direct reading of the log, and the log was wrong.

This is not the engine's fault to fix alone. The check mark means "node executed", which is a defensible thing for a generic runner to report. What is missing is the pipeline saying, at the moment it parks, what it decided and why.

`se show <runId>` does not close the gap either: on a parked run it prints status and verdict fields, not the pending approval's title or summary.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — `stageBlock`, where the verdict is computed and the Approval is constructed. Emitting the verdict to the log stream at gate time is the direct fix.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — `cmd_show`, which should print a pending approval's title and reasons when the run is `waiting-approval`.
- Consider whether `se logs` should render gate verdicts distinctly from node completion at all.

## Open decisions

- **Where the verdict should be printed.** At gate time (one line per gate, always, green or red) is simplest and makes the log self-describing. Only on red is quieter but leaves the green case unexplained, so a reader still cannot tell a printed gate from a silent one.
- **Whether `se approve` should refuse a blind approval.** Requiring the operator to have seen the reasons — by printing them as part of the approve command, or by requiring a confirmation that echoes the verdict — turns the approval into an informed decision. It also adds friction to the one path that is already tedious.
- **Whether the check mark itself should change.** Suppressing or altering the engine's node-completion mark for gate nodes may not be possible from workflow code; if it is not, the compensating log line is the whole fix and must be prominent enough to be read.

## Resolution

The verdict now reaches the screen on three surfaces, and the check mark was left alone — it belongs to the engine and honestly means "the node finished".

**The gate announces itself in the log.** `gateAnnouncement` (`home/private_dot_claude/dot_smithers/workflows/lib/gate-announce.ts`) builds the block; `stageBlock` in `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` calls it from inside the gate Task, so it prints exactly once per gate execution rather than once per render frame. A green gate gets one quiet line (`GATE work: GREEN`). A red one gets a ruled block. Rendered from the real verdict row of `run-1786718288581`:

```
────────────────────────────────────────────────────────────────────────
GATE work: FAILED — the run is about to pause for your decision
  why: validate-cmd exited with code 1
  why: validate-cmd output tail: atterns.
       No files found matching the given patterns.
        FAIL  workload-comparison/result.test.ts
       Error: Cannot find module '…/@membranehq/sdk/dist/index.node.js'
       error: script "test:scripts" exited with code 1
  approve = ONE more attempt of this stage (it will be re-run and re-paid) | deny = abort the run
────────────────────────────────────────────────────────────────────────
```

The last line is the half that mattered most. The missing verdict was only part of the trap; the other part was that "approve" at a red work gate means *retry the stage*, which reads as "continue" to anyone who has not read `stageBlock`. All three offers are now spelled out: waive-and-continue, one-more-attempt, and stop-with-a-report after the second failure.

**`se show` prints the pending request.** The engine already stored it — `_smithers_approvals.request_json` carries `title` and `summary` — and nothing rendered it. `pending_approvals_json` / `print_pending_approvals` in `home/private_dot_claude/dot_smithers/bin/executable_se` read those rows; the human output gains a `DECISION REQUIRED` block, and `--json` gains a `pendingApprovals` array. Side by side on the same fixture, old deployed launcher against new:

```
=== OLD ===                          === NEW ===
run: run-1                           run: run-1
status: —                            status: —
…ten dashes, nothing else…           …ten dashes…

                                     ─── DECISION REQUIRED: approve-work-1 ───
                                     work gate is failed — approve ONE extra attempt
                                     validate-cmd exited with code 1
```

**`se approve` and `se deny` print the request before recording the decision.** A blind approval is no longer possible without deliberately ignoring the text on screen. The usage line that read "approve a paused run (continue past the gate)" was itself part of the defect and now states what approve actually does.

Docs updated so the wrong reading is named explicitly: `docs/se-pipeline.md` ("галочка в логе — не вердикт", with this run as the example) and the `se-work` skill, which previously told an agent to gather context with `se logs` without warning that its check marks are not verdicts.

Verified: 428 bun tests (9 new in `gate-announce.test.ts`), 108 bats tests (4 new in `tests/scripts.bats`, covering the pending-approval block, the approve echo, the absence of the block when nothing is pending, and the corrected usage text), shellcheck clean. The launcher tests were run against the old deployed `se` as a mutation check and produce no decision block there.

Not covered: no live run has printed the announcement yet — it is proven by rendering real persisted verdicts through the same function the pipeline calls, not by a pipeline execution.
