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

Installed Herdr v0.9.1 supports a candidate narrow recovery protocol. A durable
intent records the isolated server config root, session, pane, stable terminal
identity, source, agent, and reserved release sequence. An independently
invoked recovery process verifies the terminal identity, then calls
`pane release-agent` with that reserved sequence.

This is not a runtime rollout or a full gate pass. The candidate passed the
following real-Herdr cases on 2026-09-29:

| Case | Observed result |
| --- | --- |
| Crash after renamed old claim; independent recovery process | The durable owner released the claim and `agent get` became `agent_not_found`. |
| Same-source successor at N+10; delayed old release at N+1 | The successor remained `working` with the same alias and terminal; its release at N+11 removed the record. |
| Foreign successor before native launch | The successor became published `working`; a source-scoped old clear did not change it. |
| Native Claude handoff | A resolved `/opt/homebrew/bin/claude` process, not a shell function, reported `agent_session.source = herdr:claude`; `agent explain --json` matched `live_prompt_box`. The foreign successor released and the same alias/terminal remained. A delayed old release also preserved them. |
| Repeated recovery and closed pane | Two recovery processes left no claim; after pane close a restarted owner settled without retargeting. |

Each transition is emitted as JSON to stdout and the complete agent/explain and
socket-response trace is written to
`/Users/seigiard/.claude/artifacts/377/proof/ownership-proof-<timestamp>.json`.
The latest measured trace is `ownership-proof-1790700075.json`.

## Rejected alternative

`pane.clear_agent_authority` is a real raw socket method in v0.9.1. It is
source-scoped and therefore safely ignores a foreign active authority. It does
not meet R1: on a renamed temporary claim it removes lifecycle authority but
leaves an alias-only `unknown` record. It cannot replace `release-agent` for
cleanup. The probe records that state explicitly.

## Rerun

```sh
MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 python3 tests/helpers/intercom_claim_ownership_probe.py
```

The probe refuses without the opt-in and outside a Herdr-managed caller. It
creates a server under `/tmp`, starts only owned panes, writes raw evidence under
the approved artifacts root, and stops/deletes the session in `finally`.

## Remaining gate

The full implementation gate is still **UNVERIFIED**. The next probe rounds
must cover crash before declaration and before receipt, post-release intent
retirement, server restart, pane move, process-start/PID reuse, concurrent
recovery ordering, real OpenCode early exit, Pi print and interactive
enrollment, Claude/`cci` process relation, and native-versus-wrapped terminal,
signal, job-control, and exit-status controls. No addendum was made to the
implementation specification, no managed path changed, and task 377-2 remains
unauthorized.

PR #378 was read only as an OpenCode/Pi reference. This evidence runs against
the installed Herdr v0.9.1 and the current branch's existing launcher; it does
not merge or modify #378, run `chezmoi apply`, access credentials, or touch a
user pane/server.
