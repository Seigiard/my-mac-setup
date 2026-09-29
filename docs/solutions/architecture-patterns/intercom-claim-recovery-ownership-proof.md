---
title: Intercom claim recovery ownership proof
date: 2026-09-29
category: architecture-patterns
module: herdr-agent-intercom
problem_type: ownership-proof
status: in-progress
---

# Intercom claim recovery ownership proof

## Current evidence

Installed Herdr v0.9.1 supports a narrow recovery-owner prototype. Its real
restart owner is an owned temporary macOS `launchd` job in the current user's
`gui/<uid>` domain. The job has `KeepAlive = true` and runs only the recovery
observer, not a client supervisor. Its plist, logs, PID record, and intents are
under the proof's temporary scratch directory; `launchctl bootout` removes it.

Before any `report-agent` claim, an atomic fsync-and-rename intent records the
server config root/session, connected server PID and process-start identity,
stable pane/terminal identity, agent kind, claimant source, ordered claim and
reserved release sequences, plus the child PID and `ps lstart` identity (read
under a fixed locale and timezone). `phase: intent` is distinct from
`phase: acquired`, and only the latter has a successful claim acknowledgment.
The observer polls process identity, never a TTL. A failed process lookup is
unknown unless the kernel confirms absence; it is not an exit. Before each RPC,
the observer checks the peer PID and start identity on the connected descriptor
used for that request. The mutation does not reconnect after that check. Herdr
closes the connection after one response, so checking an inode and later opening
an unfenced CLI connection would not provide this boundary.

On confirmed exit the observer releases exactly the reserved source/sequence,
then verifies the result. An unacknowledged acquisition stays pending while the
pane has no claim: the request may still arrive. A later claim is recovered.
An acknowledged claim can retire without mutation when a concrete published
state witnesses lifecycle takeover. Moved panes follow their stable terminal
identity. A confirmed ended server instance retires only its local obligation;
the replacement server is not mutated. Unavailable observations remain pending.

This is not a runtime rollout or a full gate pass. The prototype passed the
following real-Herdr cases on 2026-09-29:

| Case | Observed result |
| --- | --- |
| Killed observer, then actual child exit | `launchd` restarted the observer after `SIGKILL`; the new PID consumed the same `acquired` intent without a test-triggered recover call. The exact claim disappeared from `agent get`. |
| Failed process lookup | A real live process retained its claim when the process reader failed. The same claim was released after confirmed process exit. |
| Crash windows | An unresolved acquisition stayed pending without creating a record and recovered a request arriving after exit. Claim-before-acknowledgment and renamed claim both released. A restored post-release obligation retired safely. |
| Two cleanup attempts | Two independent owned launchd observers read the same durable intent; repeated exact release left no record. |
| Unavailable socket and stale PID/start identity | Hiding the real socket retained the obligation; restoring it resumed cleanup. A mismatched saved start identity released the old claim while leaving the replacement process alive. This models PID reuse; it does not claim the kernel recycled a PID in the probe. |
| Fenced newer same-source claim | The observer read the old terminal then paused. A new same-source `N+10` claim arrived before old `N+1` release. Herdr preserved the newer published `working` record; only `N+11` removed it. |
| Real server restart in the fence | The observer read first, then the owned server was stopped and restarted. Kernel peer identities proved the server process changed. The observer retired its original-server obligation without touching a new server's named `working` record. |
| Lifecycle takeover | The observer retired bookkeeping while the original process remained alive, preserving the new owner's alias and published `working` state. |
| Pane move | A move to a new workspace retained terminal identity. Cleanup recorded and used the new pane coordinate. Herdr also resolved the old coordinate to that moved pane; the probe reads the returned identity rather than assuming lookup failure. |
| Same-source successor at N+10; delayed old release at N+1 | The successor remained `working` with the same alias and terminal; its release at N+11 removed the record. |
| Foreign successor before native launch | The successor became published `working`; a source-scoped old clear did not change it. |
| Native Claude handoff | **Not accepted in this proof.** The prior trace showed published `unknown` while `agent explain --json` matched `live_prompt_box`; a computed rule is not evidence that the held-authority window ended. |
| Repeated cleanup and closed pane | Two observers left no claim; after pane close no cleanup retargeted another resource. |
| Pending managed native successor | With an ephemeral shell `claude` barrier, real `herdr agent start` reserved the pending alias before native exec. After a foreign successor released, old A's delayed `release-agent` retained the exact pending alias, terminal, and `unknown` state. |

Each transition is emitted as JSON to stdout and the complete agent/explain
trace, verdicts, and recovery latency is written to the
directory selected by `MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR` (or the OS temp
directory). The corrected owner run was `ownership-proof-1790705557.json`:
twelve cases passed. Its measured recovery latency was 0.980 seconds. The probe's
wait is a hang guard, not a production latency assertion. No production budget
is selected until the remaining client controls pass.

Regression sensitivity was observed. Before the process-observation correction,
a failed reader deleted a real live process's claim. Disabling the uncertain
acquisition guard discarded an unacknowledged request. Restoring the corrections
made both cases pass. The move check also failed before canonical coordinates
were saved from Herdr's returned pane identity.

The process-reader control now fails only the selected client's `ps` lookup;
server-peer identity reads remain available. A fresh calibration restored the
bug by treating that lookup failure as death: the live agent record disappeared
and the control failed. With the correct reader, the live claim remained and
confirmed exit released it. All twelve owner cases passed in that run. This
removes the earlier possibility that failed server-peer lookup, rather than
client liveness handling, kept the control green. The owner-only command still
returns 1 until the separate full client gate is complete.

## Rejected alternative

`pane.clear_agent_authority` is a real raw socket method in v0.9.1. It is
source-scoped and therefore safely ignores a foreign active authority. It does
not meet R1: on a renamed temporary claim it removes lifecycle authority but
leaves an alias-only `unknown` record. It cannot replace `release-agent` for
cleanup. The probe records that state explicitly.

## Rerun

```sh
MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_ownership_probe.py
```

The probe refuses without the opt-in and outside a Herdr-managed caller. It
creates a server under `/tmp`, starts only owned panes and a uniquely labelled
launchd job, writes raw evidence under the approved artifacts root, then boots
out the job and stops/deletes the session in `finally`.

## Remaining gate

The full implementation gate is still **UNVERIFIED**. This proof covers only
the automatic recovery owner and its claim transitions. The parent should use
the prototype's resolved native executable and child PID/start-identity pattern
for subsequent real-client controls. It does not prove the Claude/`cci`
relationship, OpenCode early exit, Pi print or interactive enrollment, or
native-versus-wrapped terminal, signal, job-control, and exit-status behavior.
No managed path changed.

PR #378 was read only as an OpenCode/Pi reference. This evidence runs against
the installed Herdr v0.9.1 and the current branch's existing launcher; it does
not merge or modify #378, run `chezmoi apply`, print credentials, or touch a
user pane/server.
