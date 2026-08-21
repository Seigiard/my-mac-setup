---
title: "The owner process exits after every approval and the run stalls until someone runs se resume"
short_description: "The owner process exits after every approval and the run stalls until someone runs se resume"
type: "bug"
category: "se-pipeline"
tags: ["se-pipeline","bug"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-15"
---

# Every approval strands the run in waiting-event

## Why this exists

When a pipeline run parks for an approval, the owner process exits. Approving does not restart it. The run sits in `waiting-event` until an operator runs `se resume <runId>` by hand, and this repeats at every gate that parks.

Observed on `run-1786718288581` at both approval points, and on the run before it — the operator's report calls it "уже второй раз подряд" and says they had to install their own watchdog that calls `se resume` on the stall, so that each gate stops requiring manual intervention.

The trace is visible in the log: a ninety-second gap between the approval and the run restarting, which is the operator noticing and intervening.

```
[00:09:06] ⏸ approve-work-2 waiting for approval
[00:09:06] ↺ Run status: waiting-approval
[00:10:36] ✓ Approved: approve-work-2
[00:10:45] ▶ Run started
```

The behaviour is already known and documented as a workaround rather than a defect. The `se-work` skill instructs: "If `se show` still reports the run parked after approve — the owner process already exited — `se resume <runId>` continues it." An operator who follows the skill gets there eventually; an operator watching the log sees a run that simply stopped.

The cost is not just attention. A durable pipeline whose whole selling point is surviving without supervision requires supervision at exactly the points where it pauses, which are the points a human already had to attend to. Combined with the log not printing why it parked (`docs/issues/2026-08-14-016-run-log-marks-a-failed-gate-as-passed.md`), a parked run looks indistinguishable from a dead one.

## Scope

- `home/private_dot_claude/dot_smithers/bin/executable_se` — `cmd_approve`, which today records the approval and returns.
- Whatever owns the run process lifetime: whether the launcher should stay resident across a park, or whether approve should hand off to a resume.
- `docs/se-pipeline.md` and the `se-work` skill, both of which currently document the manual step as expected behaviour.

## Open decisions

- **Whether `se approve` should resume automatically.** It is the smallest change and matches what every operator does next anyway. It also merges two operations that are currently separable, which matters if an operator wants to approve several gates before resuming.
- **Or whether the owner process should survive a park.** That removes the stall class entirely rather than papering over it, at the cost of a long-lived process holding the run — and the heartbeat/ownership machinery already assumes an owner can die and be taken over.
- **What `se show` should say about a parked-and-approved run.** Right now the state is legible only to someone who knows `waiting-event` means "approved, nobody driving". It should name the next command.
- **Whether the operator's watchdog belongs in the tool.** Someone wrote a supervisor loop around `se` to make the pipeline usable. If that loop is the correct behaviour, it belongs in `se`, not in each operator's shell history.

## Resolution

`se approve` and `se deny` now record the decision and then drive the run, so the manual `se resume` after every gate is gone. Both share one code path (`cmd_decide` in `home/private_dot_claude/dot_smithers/bin/executable_se`), which prints the pending request, delegates the decision to the engine, and calls `resume_after_decision`.

**The stall, measured rather than described.** The run's own event log gives the exact cost:

```
$ sqlite3 ~/.claude/.smithers/smithers.db \
  "SELECT datetime(timestamp_ms/1000,'unixepoch','localtime') AS t, type
   FROM _smithers_events WHERE run_id='run-1786718288581'
   AND type IN ('RunStarted','ApprovalRequested','RunFinished') ORDER BY seq;"
16:38:09  RunStarted
16:41:43  ApprovalRequested     ← owner exits here
16:44:47  RunStarted            ← manual `se resume`, 3m04s later
16:47:16  ApprovalRequested
16:48:55  RunStarted
16:48:55  RunFinished
```

The first approval was recorded at 16:42:24 (`_smithers_approvals.decided_at_ms`). The run did not move for another **2 minutes 23 seconds**, and only because a human noticed and typed a command. The second gap is 9 seconds — that is the operator's own watchdog, written during the run to make the tool usable.

**Resuming only when nobody owns the run.** Two engines on one run corrupt its state, so the automatic resume is gated on ownership. `runtime_owner_id` holds `pid:<pid>:<uuid>` while a process drives the run and is **cleared when the run parks**, which is what makes the check cheap and unambiguous. `run_owner_alive` treats an empty owner as nobody, a live pid as owned, and any other shape as owned — an unreadable owner blocks the resume rather than permitting it. `resume_after_decision` also returns early on a terminal status, and waits two seconds first so an engine that was going to claim the run gets to.

The rule was checked against the real database, not only fixtures:

```
run-1786701839118      waiting-event   owner=''   no owner -> resumable
run-1786718288581      finished        owner=''   terminal, never reaches the owner check
run-1786717378769      finished        owner=''   terminal, never reaches the owner check
```

The live-pid branch is the same check used earlier in this session to confirm `pid:30067` and `pid:56450` were real running engines.

**`--no-resume` keeps the old behaviour** for deciding several gates before driving the run, which is the one case where merging the two operations would be wrong.

**Not built: the engine's own supervisor.** `smithers up --serve --supervise` polls for stale runs and resumes them (`--supervise-stale-threshold` defaults to 30s). It is the general answer to "a run stopped for any reason", including crashes this fix does not touch — but it needs a resident daemon and an HTTP server, and it reacts on a heartbeat timeout rather than immediately. Running it is worth considering separately; it does not replace making `approve` finish its own job.

Verified: 112 bats tests, 4 of them new — a parked run is resumed, `--no-resume` is not, a run owned by a live process is declined with a message, and a finished run is left alone. shellcheck clean. Runbook and the `se-work` skill updated, both of which previously documented the manual resume as expected behaviour.

Uncovered: no live pipeline run has exercised the automated path. The two halves are each proven — the approve-then-resume sequence by four manual repetitions on `run-1786718288581` and its predecessor, the automation by bats against a recording stub engine — but their composition has not run against a real parked pipeline.
