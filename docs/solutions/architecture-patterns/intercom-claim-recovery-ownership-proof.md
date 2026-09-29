---
title: Intercom claim recovery ownership proof
date: 2026-09-29
category: architecture-patterns
module: herdr-agent-intercom
problem_type: ownership-proof
status: blocked
---

# Intercom claim recovery ownership proof

## Verdict

**BLOCKED.** The first live ownership scenario preserves a real detected
successor, but it does not prove the required recovery protocol or its owner.
The repository has no restartable recovery observer or durable launch intent in
this proof-only scope. That is the smallest missing capability: an independently
restartable owner that can durably retain and consume the reserved release
sequence, server identity, stable terminal identity, and process-start identity.
It must exist before gate groups 2 through 5 can be honestly exercised.

This is not an upstream Herdr API blocker. Source inspection and the measured
case show that `release-agent` preserves an alive screen-detected process and
its alias after foreign takeover authority is released. A pre-read followed by
unconditional release remains insufficient for a future runtime protocol, but
the first scenario alone did not falsify reserved sequence ordering.

## Rerun

This is an opt-in live probe. It must be run from a Herdr-managed pane and
creates one isolated Herdr session with a disposable owned pane. It never
targets the caller pane or server.

```sh
MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 python3 tests/helpers/intercom_claim_ownership_probe.py
```

Expected result on the measured implementation is exit status 1, a `PASS` line,
an `INCOMPLETE` line, and `CLEANUP: stopped owned session ...`. Exit status 1
means the full gate remains blocked, not that this scenario failed.

## Method and observation

The probe records the new pane's `terminal_id`, starts the installed `claude`
client only in that pane, and waits for real Herdr screen detection with a
non-`none` `agent explain` rule. It then uses causal command barriers:

1. Old source `mms-377-old-launch` reports `claude` at sequence N.
2. Successor source `mms-377-successor` reports `claude` at N+10.
3. The successor releases itself at N+11, returning authority to the still-live
   screen-detected process.
4. The probe verifies the successor is on the original `terminal_id`.
5. Old source releases with N+1. Herdr acknowledges the command and the
   screen-detected record retains the same terminal identity and alias.

The terminal identity and alias checks distinguish the actual live successor
from a record-presence-only probe. Every CLI command's status is checked before
its state is interpreted. The `finally` block stops the isolated server and
removes its `/tmp` state whether the assertion passes, fails, or raises.

## Limits and scope

This is one passing scenario from required gate group 1, not a completed
recovery design. The remaining group-1 cases and gate groups 2 through 5 are
**UNVERIFIED**: crash windows, observer death/restart, pane/server changes,
real client lifecycle relations, and native-versus-wrapped
terminal/signal/exit controls were not exercised. No recovery owner, latency
budget, polling cadence, durable-intent format, or runtime cleanup behavior has
been selected.

The current branch contains the merged #380 CI repair and has the existing
Claude-only claim path. PR #378 (`fix/intercom-enrol-opencode-and-pi`) was read
only as a reference; it is not merged or modified by this proof. The probe uses
installed Herdr v0.9.1, not a fake server and not code from either PR.

The probe names its owned resources with the `mms-377-` source prefix and closes
the generated pane. It does not run `chezmoi apply`, change managed `home/`
files, access credentials, stop a server, or mutate a non-owned pane.
