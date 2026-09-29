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
server config root/session/socket identity, stable pane/terminal identity, agent
kind, claimant source, monotonic claim and reserved release sequences, plus the
child PID and `ps lstart` identity. `phase: intent` is distinct from
`phase: acquired`, and only the latter has a successful claim acknowledgment.
The observer polls process identity, never a TTL. On confirmed exit it verifies
the socket and terminal, calls `release-agent` with exactly the reserved source
and sequence, reads `agent get`, and retires the record only after
`agent_not_found`. Unavailable sockets and changed identities retain an
`acquired` obligation with a pending diagnostic.

This is not a runtime rollout or a full gate pass. The prototype passed the
following real-Herdr cases on 2026-09-29:

| Case | Observed result |
| --- | --- |
| Killed observer, then actual child exit | `launchd` restarted the observer after `SIGKILL`; the new PID consumed the same `acquired` intent without a test-triggered recover call. The exact claim disappeared from `agent get`. |
| Crash windows | Intent before claim created no record; claim-before-acknowledgment and renamed claim both released after the child exited. A deliberately restored `acquired` record after release was retired safely. |
| Two cleanup attempts | Two independent owned launchd observers read the same durable intent; repeated exact release left no record. |
| Unavailable socket and stale PID/start identity | The observer retained `acquired` with `pending: socket unavailable`; an explicit retry marker restored its saved endpoint and cleanup completed. A changed start identity is not treated as a live PID. |
| Fenced newer same-source claim | The observer read the old terminal then paused. A new same-source `N+10` claim arrived before old `N+1` release. Herdr preserved the newer published `working` record; only `N+11` removed it. |
| Real server restart in the fence | The observer read first, the owned session was stopped and restarted, then it released with the original reserved sequence. Herdr retained its endpoint and terminal identity across this restart and the exact old claim alone was removed. v0.9.1 exposes no separate server-instance ID beyond that connection identity. |
| Same-source successor at N+10; delayed old release at N+1 | The successor remained `working` with the same alias and terminal; its release at N+11 removed the record. |
| Foreign successor before native launch | The successor became published `working`; a source-scoped old clear did not change it. |
| Native Claude handoff | **Not accepted in this proof.** The prior trace showed published `unknown` while `agent explain --json` matched `live_prompt_box`; a computed rule is not evidence that the held-authority window ended. |
| Repeated cleanup and closed pane | Two observers left no claim; after pane close no cleanup retargeted another resource. |
| Pending managed native successor | With an ephemeral shell `claude` barrier, real `herdr agent start` reserved the pending alias before native exec. After a foreign successor released, old A's delayed `release-agent` retained the exact pending alias, terminal, and `unknown` state. |

Each transition is emitted as JSON to stdout and the complete agent/explain
trace, verdicts, and recovery latency is written to the
directory selected by `MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR` (or the OS temp
directory). The successful run was
`/Users/seigiard/.claude/artifacts/377/proof/ownership-proof-1790701489.json`.
Its healthy recovery latency was below the prototype's five-second bounded
wait; the raw artifact carries the measured value. This is a measurement, not a
selected production latency budget.

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
not merge or modify #378, run `chezmoi apply`, access credentials, or touch a
user pane/server.
