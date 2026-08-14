---
title: se resume's hint tells the operator to use --force true, a flag se resume does not have
type: bug
date: 2026-08-14
status: open
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
