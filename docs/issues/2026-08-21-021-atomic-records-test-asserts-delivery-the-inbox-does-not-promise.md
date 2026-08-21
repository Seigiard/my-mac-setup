---
title: The atomic-records test asserts one-shot delivery the fail-open inbox does not promise
type: bug
date: 2026-08-21
status: done
closed: 2026-08-21
---

## Why this exists

`herdr-task-sync atomic records never expose truncation or mixed fields`
(`tests/scripts.bats`) failed on three CI runs within minutes on 2026-08-21 —
`test-ubuntu` on run `32468923311` and `test-macos` on runs `32468558665` and
`32468832954` — on three branches whose diffs touch no herdr-task-sync code. All
three show the same signature: `hts_wait_for_task_slug "$task" atomic-40` runs
to its ceiling, no error and no kill anywhere before it, then post-teardown
ENOENT noise from paths inside the already-deleted `$HTS_WORK`
(`bad-reader: No such file or directory`).

Two defects combined:

1. **The primary failure.** The engine's inbox is fail-open by design: both the
   enqueue and the worker commit take `control.lock` with a bounded
   `acquire_claim` (`INBOX_LOCK_ATTEMPTS`, default 20) and drop the request
   silently on exhaustion (`acquire_claim ... || exit 0` in the enqueue path of
   `home/dot_local/bin/executable_herdr-task-sync`; `|| return 1` →
   `abort_worker` in `commit_task_result`). The test fires 40 rapid sequential
   `--set` enqueues — exactly the load that provokes those drops — and then
   asserts one-shot delivery of the final `atomic-40`. On a `--jobs 8` CI runner
   the sentinel (or its commit) can lose its whole lock window; the slug then
   never arrives and the wait times out. Proven deterministically on the host:
   an enqueue issued while `control.lock` is held by a live owner exits 0 and
   leaves `generation` unchanged — the set vanishes without a trace; the next
   enqueue after release lands.
2. **The misleading noise.** On any assertion failure the test's backgrounded
   reader loop is never stopped: the `: > "$stop"` / `wait "$reader"` pair sits
   after the failing line. Teardown's `rm -rf "$HTS_WORK"` then races the still
   running loop — which can never terminate once its stop file's directory is
   gone — leaving an orphan spinning at 5 ms intervals for the rest of the job
   and burying the real failure under ENOENT spray.

This is the flake family `docs/issues/2026-08-20-010` predicted:
within-file parallelism exposing an assumption calibrated on an idle machine —
here a delivery assumption rather than a wall-clock one
(`docs/issues/2026-08-21-015` names the pattern).

## Scope

- `tests/scripts.bats` — the atomic-records test and `teardown()`.

## Resolution

Fixed in the same change that files this issue.

- The 40-set burst stays untouched as the load generator, and the atomicity
  assertions the reader collects stay as strict as before. Only sentinel
  delivery is made deterministic: after the burst the test re-enqueues
  `--set atomic-40` (up to 10 times, short poll between attempts) until the
  slug commits, then keeps the original full-ceiling wait as the final
  assertion. A re-enqueue also drains a pending generation whose own worker
  aborted, so both drop modes recover.
- `teardown()` now reaps `$HTS_READER_PID` (set by the test, cleared after its
  own `wait`) before deleting `$HTS_WORK`, so a failed run kills the reader
  instead of orphaning it, and the real failure output stays readable.

Verification: the drop mechanism reproduced deterministically at the engine
level (held `control.lock` → enqueue exits 0, `generation` unchanged); the
fixed test passed 15/15 focused repetitions and two full
`bats --jobs 8 --no-parallelize-across-files tests/scripts.bats` runs
(196 ok, 0 failures each); `make lint` clean. The CI race itself did not
reproduce on an idle 10-core host (5 starved-lock runs, 4 runs under 12 busy
loops with `HERDR_TASK_SYNC_LOCK_ATTEMPTS=1` — all green), consistent with
2026-08-20-010's finding that CPU pressure alone is the wrong contention
profile; the deterministic engine-level proof is the evidence the fix rests on.

The engine's fail-open inbox is deliberate and stays as shipped: in production
a dropped request costs one pane-label refresh and the next event repairs it.
The defect was the test demanding a stronger contract than the engine offers.
