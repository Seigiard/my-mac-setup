# Recover failed Intercom launches without restarting an agent

Status: approved outcome; implementation blocked on the real-Herdr ownership
gate below. This document specifies future behavior. It does not claim that the
launcher already recovers automatically.

Related: [#377](https://github.com/Seigiard/my-mac-setup/issues/377),
[#376](https://github.com/Seigiard/my-mac-setup/issues/376),
[#378](https://github.com/Seigiard/my-mac-setup/pull/378).
Decision: [ADR-0021](../decisions/0021-recover-intercom-launch-claims-without-a-successor.md).

## Purpose and scope

A failed launch must stop leaving the pane stuck on `unknown`. Recovery must run
without another agent launch or prompt, and must not disturb a newer agent in
the same pane. Keep the existing pool alias and collision boundary for fresh
panes. Preserve each client's supported terminal, signal, argument, and exit
behavior.

The implementation covers launch claims created by this launcher for Claude,
OpenCode, and Pi on the host. OpenCode/Pi acquisition depends on #378; integrate
that work or rebase after it lands rather than implement a second enrollment
path. Used-pane reconciliation remains a separate path. A pre-existing record
that this launch did not create is not its cleanup responsibility.

This does not add Codex enrollment, remote placement support, task supervision,
or a generic background-worker service. Existing legacy markers lack enough
ownership information for automatic adoption: keep their current successor
recovery path and report them separately. The new guarantee applies to claims
created by the new protocol.

## Observable requirements

| ID | Situation | Required result |
|---|---|---|
| R1 | A launch exits or fails before reporting lifecycle state | Remove its own temporary claim without a successor session or prompt. Native pane detection can resume; do not force an `idle` label. |
| R2 | A newer launch occupies the same pane before old cleanup runs | Preserve the newer record, alias, lifecycle authority, and Intercom identity. Old cleanup cannot rename, release, or erase its recovery record. |
| R3 | A client takes over lifecycle reporting | Retire the launcher's recovery responsibility without releasing the client's authority. Claude's handoff to screen detection must retain its alias. |
| R4 | An interactive client is alive but has received no prompt | Keep its alias and enrollment. Age alone is not evidence that the claim is abandoned. |
| R5 | Herdr is temporarily unreachable or a process identity cannot be verified | Keep the recovery obligation, expose a pending diagnostic, and retry independently of another launch. Do not claim success or infer death from a failed lookup. |
| R6 | The cleanup owner crashes while its claim remains | Recovery resumes from durable intent without another agent launch. The recovery mechanism itself must have a proved restart owner. |
| R7 | A pane closes, moves, or the server restarts | Use stable terminal and server identity to avoid retargeting stale pane coordinates. Remove an orphaned local record only after establishing that its resource is gone or its obligation was settled. |
| R8 | Known utility, completion, non-TTY Pi, or disabled-integration launch | Bypass new pane claims when the mode is known. Hand through native arguments. A missed classification still obeys R1 after exit. |
| R9 | Nested launch or a child pane inherits launcher environment | It cannot adopt a different launch's cleanup authority. A child pane resolves its own identity. |
| R10 | A claim or recovery intent cannot be established | Create no new unowned claim. Preserve native client startup, warn that automatic enrollment is unavailable, and reuse only an independently valid existing alias. |

The healthy observer schedules a recovery check at least once every five seconds.
After confirmed exit, release and verification must settle within two successful
checks with Herdr reachable and ownership known. A failed observation does not
count as successful. These are scheduling requirements, not a claim that an
unreachable server can be repaired within a wall-clock deadline. Verify ordering
with causal barriers; record actual recovery latency separately.

A long-lived process with no lifecycle reports is not known to be dead. Known
headless modes bypass acquisition; an unrecognized live process may retain the
temporary claim until it exits. This specification does not make a blanket
"all unknown modes enroll harmlessly" promise.

## Ownership and transitions

One launch has one recovery obligation. It identifies the server instance,
stable terminal, launch generation, claim source, agent kind, and the process
identity being observed. A PID without a start identity is insufficient. For
Claude, define how the observed `cci` process relates to the actual client before
using its exit as evidence.

```text
record intent → acquire claim and alias → start client
  client takes over / Claude detection handoff → confirm handoff → retire intent
  launch exits without handoff               → release own claim → verify → retire intent
  observation or release is uncertain        → retain intent and retry
```

Acquisition, release, handoff, retries, and local record deletion must all refer
to the same launch. A pre-read followed by an unconditional release is not a
safe ownership check. An exit code of zero from `report-agent` or `release-agent`
does not prove the requested transition occurred; Herdr can acknowledge ignored
reports. Confirm the resulting state. Recovery does not reserve another alias
or retry a late collision under a different identity.

Preserve Pi's loader invariant: `HERDR_AGENT_INTERCOM_PI_LOAD` must identify the
actual Pi process. Preserve standard streams, job control, signal behavior, and
the native client's exit status if the implementation changes the process tree.

## Required implementation gate: prove ownership before choosing the owner

Use real Herdr and disposable, owned panes. The gate produces a checked-in
evidence note and an implementation addendum to this specification. It must name
the observation process, its restart owner, the process identity it follows,
the server/terminal identity scheme, the claim/release ordering protocol, and
how uncertainty is exposed. These are blocked design decisions, not discretion
to fill in while shipping the launcher.

The following primitive probes passed on installed Herdr 0.9.1 on 2026-09-29:

| Sequence in a fresh shell pane | Observed result |
|---|---|
| Same source: claim at N, newer claim at N+10, delayed release at N+20 | Newer record disappears. Computing a fresh release timestamp is unsafe. |
| Same source: claim at N, newer claim at N+10, old release at N+1 | Newer record remains. Its own release at N+11 removes it. |
| Source A claims, source B takes authority, A releases | B's record remains. B's own release removes it. |

All commands returned success, including the ignored releases; state reads
distinguished them. Each probe asserted a missing record before declaration,
an existing record after it, and the expected presence or absence after release.
All three probe panes were closed. These probes ran lifecycle declarations, not
real agent clients, and did not test a production observer or alias preservation.

Reserved release sequences are a candidate, not a selected protocol. Herdr
[accepts sequences per source](https://github.com/herdrdev/herdr/blob/v0.9.1/src/terminal/state.rs#L1673-L1687)
and its [release rules](https://github.com/herdrdev/herdr/blob/v0.9.1/src/terminal/state.rs#L1747-L1796)
also have a path with no active hook authority. Unique sources alone do not prove
isolation. The full gate must exercise:

1. Same-source successor, different-source takeover, no remaining hook authority,
   a live detected successor, repeated release, and interleaved report/release.
2. Crash before declaration, after declaration but before its receipt, after
   rename, after release but before local retirement, and death of the observer.
3. Moved/closed pane, server restart, PID reuse evidence, and two simultaneous
   cleanup attempts. Use synchronization barriers rather than hoping to hit a race.
4. A real Claude launch and `cci` exit relationship; real OpenCode exit before
   its first report; real Pi print-mode exit. Verify alias preservation when a
   client takes over, not merely survival of an unnamed test record.

Gate passes only with observed safe outcomes and a reviewed owner/protocol
addendum. A skip or a fake server is not a pass. If isolation cannot be proved,
keep runtime unchanged and return with the precise upstream API requirement or
the client-side registration alternative. Do not silently weaken R1 or R2.

## Verification ownership

The consumer is a person or automation reading Herdr state after a failed launch.
The independent oracle is real client exit plus Herdr's resulting record and
authority, including a real surviving successor. Permanent tests should protect
the repository-owned cleanup transitions, not encode another copy of client
argument grammar. Extend the existing launcher/release cases in
`tests/bashunit/scripts_test.sh`; keep live conformance skips visible.

Acceptance includes invalid Pi input with a valid utility control, normal exit,
termination before first report, non-TTY Pi, no-prompt live clients, real takeover,
delayed old cleanup, lost observation and recovery-owner restart. Prove that
cleanup runs when no second client is launched. A regression that deletes the
newer record must turn the isolation check red.

Apply `docs/agent-verification.md` to the final implementation. New managed paths
or deployment-dependent lifecycle behavior require `make test-ubuntu`. Ubuntu
and macOS CI must pass before merge. This specification-only change adds no
runtime tests: no cleanup implementation exists for them to exercise yet.

## Deferred runtime and documentation changes

- Implement the proved lifecycle protocol in the launcher/release path and its
  selected observation host. Preserve the #378 enrollment work.
- Write durable intent for every newly acquired supported-client claim; handle
  takeover and local-record retirement without the current Claude-only gate.
- Replace the first-prompt-only recovery description in
  `home/private_dot_claude/shared/agent-intercom-contract.md` only after proving
  the new behavior. State the legacy-marker boundary and pending-recovery case.
- Update ADR-0018's launch lifecycle section with the demonstrated mechanism and
  deployed scope. Keep its fresh/used-pane distinction and alias-collision rules.
- Add the behavioral and real-boundary evidence described above. Do not remove
  the documented early-exit windows until the implementation demonstrates R1–R10.

Keep the delivery PR open while these changes are built into it. This document
and ADR can be reviewed now; the full change is not ready to merge until the
implementation and its evidence arrive.
