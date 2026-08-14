---
title: The owner process exits after every approval and the run stalls until someone runs se resume
type: bug
date: 2026-08-14
status: open
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
