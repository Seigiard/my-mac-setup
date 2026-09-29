---
title: Intercom claim recovery ownership proof
date: 2026-09-29
category: architecture-patterns
module: herdr-agent-intercom
problem_type: ownership-proof
status: in-progress
---

# Intercom claim recovery ownership proof

## Boundary

This is opt-in proof tooling, not a runtime rollout. The full implementation
gate remains **UNVERIFIED** until all real-client terminal controls pass and
the owner/protocol addendum is reviewed. No managed path has changed.

The owner probe runs installed Herdr 0.9.1 in an isolated named session. A
temporary macOS `launchd` job in `gui/<uid>` restarts the observer with
`KeepAlive = true`. Each job has its own plist, logs and PID receipt. Teardown
boots it out and confirms process exit before deleting its files. Cleanup
failures preserve the scratch tree for diagnosis.

## Candidate protocol

Before acquisition, a durable fsync-and-rename intent identifies the connected
server PID/start identity, stable terminal, launch generation, source, reserved
sequences, and process PID/start identity. `intent` means acquisition is not
acknowledged; `acquired` follows claim readback. An unacknowledged operation
cannot retire merely because the pane has no record: the request can arrive
after its process exits.

An inode-stable sidecar lock serializes acknowledgement, native binding,
handoff and observation for one intent. JSON rename alone is not that lock.
Observer lock attempts are nonblocking, so a busy intent does not stop the
observer from checking others. Test barriers have deadlines and failure-path
release guards; they are not part of the proposed deployed protocol.

Every RPC verifies the kernel peer PID/start identity on the descriptor used
for that request. Herdr closes the connection after a response. A path or inode
read followed by another connection would not provide this fence. Socket inode
data in client evidence is diagnostic only.

The observer follows process identity, not age. Failed process reads remain
pending unless the kernel establishes absence. A concrete successor state
retires an acknowledged launch without a release, whether the publisher is a
newer same-source launch or a client integration. An unknown record does not
expose its authority source or claim sequence through `agent.get`. An ignored
release therefore remains pending; the prototype bounds these release retries
to one per two seconds instead of inferring ownership from RPC success.

Moved panes are resolved by stable terminal identity. A changed server is never
mutated with the old intent. Before retirement, read-only requests fenced to the
replacement server must establish that the old terminal or its agent record is
absent. A retained record leaves an explicit pending diagnostic.

### Claude's native process and first prompt

`cci` probes its configured bridge with `--version` even in MCP mode. That
short-lived process is not the interactive client. The proof bridge passes the
utility through, then binds the real before-exec bridge PID while its recorded
launcher is still its live parent. The bridge and native exec share a PID.
Binding uses the same lock as cleanup. A bridge arriving after settlement
starts the native argv without cci's generated enrollment rather than reviving
the old claim.

The real first-prompt hook checks native ancestry and stable terminal identity.
It requests a source-scoped, reserved-sequence release. The client probe reserves
`N` for acquisition, `N+1` for handoff and `N+2` for final cleanup. Only a later
published concrete state retires the intent; a successful release response is
not the handoff verdict. The probe also requires the same alias and a live native
client. Input readiness is a positive `live_prompt_box` rule, separate from the
published lifecycle state being tested.

## Owner evidence

The current registered owner cases are:

| Case | Observed result |
| --- | --- |
| Native binding versus cleanup | A barrier pauses binding after its live-parent check. The launcher dies, an observer attempts cleanup, and the lock preserves the claim. The bound child then owns recovery until its own exit. |
| Failed process lookup | Failure is limited to the selected client's reader. The live claim remains; actual exit releases it. Server-peer reads still work. |
| Observer restart | `launchd` restarts a killed observer. Distinct old/new PID receipts are recorded, and the new process consumes the same intent. |
| Same-source successor | Reserved old release preserves a newer same-source working record and alias. The successor's own release removes it. |
| Concrete successor state | Bookkeeping retires while the original process is alive, without releasing or renaming the successor. |
| Moved pane | Cleanup follows the same terminal under its current coordinate. |
| Fenced old release | A post-response trace proves the delayed release ran before the successor-preservation assertion. |
| Unknown successor | The newer unknown record survives. Unavailable ownership evidence remains pending rather than being invented from RPC success. |
| Socket outage and PID incarnation | Restoring the socket resumes cleanup. A process-reader seam models a different start token for the same real PID; the replacement stays alive. This is not a claim of actual kernel PID recycling. |
| Acquisition crash windows | Presence is confirmed before cleanup, including a delayed acquisition and a claim whose acknowledgement never happened. |
| Source-scoped clear alternative | Clearing authority on a renamed claim leaves an alias-only unknown record; it cannot implement failed-launch cleanup. |
| Pending managed successor | A real `herdr agent start` reaches its pre-exec barrier. Old release preserves the reserved alias and terminal. The pane is closed before the unused native launch begins. |
| Concurrent and repeated cleanup | Both observers reach an entry barrier and attempt the same intent. The lock serializes them. Repeated release and closed-terminal replay also settle safely. |
| Server restart | The old record is confirmed absent after restart, and a new server's unrelated named record remains unchanged. |

`ownership-proof-53781559115e4cc8b82ed647a38e6942.json` records fourteen passing
owner cases and 0.947 seconds of observed recovery latency. It includes the
explicit unacknowledged-claim window and the calibrated binding race.
No production recovery budget is selected from an isolated latency sample.

Calibration found and closed a false-green timing window in the new binding
case. Its observer witness now requires an attempt that **started** after
launcher exit. Removing the lock then deletes the live child's claim and makes
the case fail; restoring it passes. A separate in-process mutation that treats
any live PID as the same incarnation fails the same-PID/different-token case;
PID plus start identity passes. The failed-client-reader regression was also
observed red and green with server-peer lookup left functional.

## Real-client evidence and remaining work

`bound-claude-11c940c973734532a536c8e1cace2d14.json` records real native Claude
survival across cci `SIGKILL`, retained-alias first-prompt handoff, and normal
`/exit`. These controls use an isolated bridge and settings file. They do not
claim that the deployed launcher already implements recovery.

The client probe stages the launcher from merged PR #378 at
`dc33b385891fdab07af303037cc1ad2e3e161471`, with only the candidate bridge entry
changed. Real clients retain PTY streams through a status-recording driver.
The pane shell survives client exit, so claim cleanup cannot pass merely because
the terminal disappeared. Remaining native/wrapped print, signal and job-control
controls must finish before the full gate can pass.

## Rerun and verdicts

```sh
MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_ownership_probe.py

MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_client_probe.py
```

Both commands require a Herdr-managed caller and create only owned resources.
The owner command returns `1` for failed cases or cleanup, `2` for refusal, and
`3` when its cases pass but the separate full client gate remains unverified.
Read the UUID-named JSON artifact for the exact executed case set. A focused
calibration is not evidence that omitted cases ran. The client command returns
`0` only when every registered client case passes; it does not replace owner
evidence or the required reviewed addendum.
