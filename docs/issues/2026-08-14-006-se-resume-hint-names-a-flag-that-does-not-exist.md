---
title: "se resume's hint tells the operator to use --force true, a flag se resume does not have"
short_description: "se resume's hint tells the operator to use --force true, a flag se resume does not have"
type: "bug"
category: "repository-maintenance"
tags: ["repository-maintenance","bug"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-14"
---

# se resume's hint names a flag that does not exist

## Why this exists

Resuming a hard-killed run fails while the dead owner's heartbeat is still fresh. `se resume` then prints:

```
se: hint: force-resuming a killed run needs '--force true', and smithers refuses while the
dead owner's heartbeat is still fresh (~30-45s) — wait and retry.
```

`--force` is not a `se resume` option. The string at `home/private_dot_claude/dot_smithers/bin/executable_se:431` is the only occurrence of "force" in the whole launcher, so an operator who follows the first half of the sentence gets an unknown-option error.

The second half of the hint is the advice that actually works: wait for the heartbeat to expire, then re-run `se resume`. Confirmed on `run-1786712117798` during host-checklist scenario 4.1 — a plain `se resume` about 50 seconds after the kill succeeded, and no completed block re-executed.

The underlying `smithers up --force true` does exist; the gap is that `se resume` never forwards it.

## Scope

`home/private_dot_claude/dot_smithers/bin/executable_se` — `cmd_resume`.

Either add a `--force` passthrough to `se resume`, or reword the hint to state the wait-and-retry path only. Adding the flag is the better fix: the wait is 30-45 seconds of an operator watching a terminal, and the engine already supports skipping it.

If the flag is added, keep the heartbeat warning in the help text. Force-resuming a run whose owner is still alive is how two engines end up driving one run.

## Open decisions

None.

## Resolution

`se resume <runId> --force` now exists, in `cmd_resume`. The flag is parsed after the run id and forwarded to both routes, `se-flow.tsx` and `se-pipeline.tsx`; an unrecognised option is rejected instead of being swallowed.

The old hint was wrong twice over, not once. `smithers up --help` shows the engine's flag is a bare `--force` switch that takes no value, so `--force true` would have been wrong syntax even against the engine directly. The rewritten hint names the two paths that work — wait and retry, or `se resume <id> --force` — keeps the warning about a live owner, and prints only when `--force` was not already given.

Verified live rather than by reading the code. `run-1786714513439` was SIGKILLed while its middle block was executing, and both resume paths were tried inside the same heartbeat window:

```
SIGKILL sent to 57616 at 1786714515
plain resume: rc=1 after 1s
code: RUN_STILL_RUNNING
message: "Run is still actively running: run-1786714513439. Use --force to resume anyway."
forced resume: rc=0 after 141s
```

The plain resume is the control: one second after the kill it was refused, which is the whole reason the flag is needed. The forced resume was issued about a second later, deep inside the 30-45 second window where the plain path refuses, and it was accepted — the 141 seconds is how long the resumed run took to finish, not a wait before acceptance. A rejection returns in under a second, as the control shows.

Resume stayed correct under the flag: `b:check` attempt 1 `cancelled`, attempt 2 `finished` under the same node id, and every block completed before the kill kept attempt 1 with no re-execution. Run status `finished`.

Docs updated in `docs/se-pipeline.md`: the command list and the resume notes now carry the flag and the do-not-force-a-live-owner warning. `make lint` clean.
