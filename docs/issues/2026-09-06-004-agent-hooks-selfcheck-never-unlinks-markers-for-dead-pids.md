---
title: "agent-hooks selfcheck never unlinks markers for dead pids"
short_description: "writeMarker() creates ~/.local/state/agent-hooks/<client>-<pid>.json on every OpenCode or Pi start and nothing ever removes one; readMarkers() filters dead pids in memory only, so the directory grows without bound across months of normal use and a reused pid can make a stale marker read as a live session in the identity report R8 relies on."
type: "bug"
category: "agent-platform"
tags: ["agent-hooks","selfcheck","housekeeping"]
date: "2026-09-06"
status: "open"
priority: "low"
---

## Why this exists

`writeMarker()` in `home/dot_local/lib/agent-hooks/selfcheck.ts` writes
`~/.local/state/agent-hooks/<client>-<pid>.json` every time an OpenCode or Pi
process loads the core. Nothing ever removes one. `readMarkers()` filters dead
pids in memory when it builds the identity report, so the report stays correct
today, but the file stays on disk forever.

Two consequences, one certain and one latent:

- The directory grows without bound. Every client restart adds a file that
  outlives the process by design and is never collected.
- Pid reuse makes a stale marker readable as live. The identity report R8
  depends on distinguishes `current`, `stale` and `unknown` by asking whether a
  marker's pid is alive. A recycled pid belonging to an unrelated process makes
  a months-old marker satisfy that test, and the report would then name a core
  identity no running client actually loaded.

The second is what makes this worth fixing rather than tolerating. The identity
report exists precisely so that cache skew after an apply is visible instead of
being a confident lie, and unbounded stale markers erode the one signal it
provides.

## Scope

Remove markers whose pid is gone. The cheapest place is opportunistic pruning:
when `writeMarker()` runs for a client, unlink any other marker for that same
client whose pid is no longer alive. Pruning inside `readMarkers()` or
`inspectIdentity()` is the alternative and covers the case where no client ever
starts again.

Whatever is chosen must not weaken the existing distinction between `stale` and
`unknown`: a live session running an out-of-date core must keep reporting
`stale`, which is the condition the report was built to surface.

## Open decisions

- Prune on write, on read, or both? Pruning on read makes a diagnostic command
  mutate state, which is a property worth deciding deliberately.
- Should a marker also carry a start time so pid reuse is detectable directly,
  rather than relying on pruning to keep the window small?
- Is there a bound worth enforcing on the directory independent of liveness, for
  the case where a client crashes in a loop?
