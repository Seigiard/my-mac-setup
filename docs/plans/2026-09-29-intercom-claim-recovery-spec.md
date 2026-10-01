# Recover failed Intercom launches without restarting an agent

Status: approved outcome and owner/protocol addendum, with a scoped upstream
suspension exception. Proof PR #382 was accepted and merged into the delivery
branch. Runtime implementation is under verification; deployment and delivery
acceptance remain separate from that proof.

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
| R4 | An interactive client is alive but has received no prompt | Keep its alias and enrollment, subject only to the upstream suspension exception below. Recovery itself must never release, rename or replace a live client's identity, including while suspended. Age or loss of foreground is not exit evidence. |
| R5 | Herdr is temporarily unreachable or a process identity cannot be verified | Keep the recovery obligation, expose a pending diagnostic, and retry independently of another launch. Do not claim success or infer death from a failed lookup. |
| R6 | The cleanup owner crashes while its claim remains | Recovery resumes from durable intent without another agent launch. The recovery mechanism itself must have a proved restart owner. |
| R7 | A pane closes, moves, or the server restarts | Use stable terminal and server identity to avoid retargeting stale pane coordinates. Remove an orphaned local record only after establishing that its resource is gone or its obligation was settled. |
| R8 | Known utility, completion, non-TTY Pi, or disabled-integration launch | Bypass new pane claims when the mode is known. Hand through native arguments. A missed classification still obeys R1 after exit. |
| R9 | Nested launch or a child pane inherits launcher environment | It cannot adopt a different launch's cleanup authority. A child pane resolves its own identity. |
| R10 | A claim or recovery intent cannot be established | Create no new unowned claim. Preserve native client startup, warn that automatic enrollment is unavailable, and reuse only an independently valid existing alias. |

Recovery runs automatically after confirmed exit, with Herdr reachable and
ownership known. The ownership gate must record measured latency and choose a
finite healthy-state recovery budget before runtime implementation is accepted.
That budget must allow event-driven or periodic observation; a polling cadence
is not selected here. Failed observations remain pending, not successful cleanup.
Verify ordering with causal barriers and measure recovery latency separately.

A long-lived process with no lifecycle reports is not known to be dead. Known
headless modes bypass acquisition; an unrecognized live process may retain the
temporary claim until it exits. This specification does not make a blanket
"all unknown modes enroll harmlessly" promise.

## Accepted upstream suspension exception

The owner permits #377 to proceed despite Herdr independently dropping a live
client's alias or registration during Ctrl-Z/fg, as tracked in
[herdrdev/herdr#1647](https://github.com/herdrdev/herdr/issues/1647). This is a
narrow exception to end-to-end suspension identity retention, not an exemption
from the recovery mechanism's responsibility for its own actions.

For each affected client and Herdr build, record a native or recovery-disabled
control that reproduces the loss, plus the corresponding wrapped observation.
Record version, PID/start identity, terminal identity and relevant state changes.
Also prove that our recovery neither releases nor renames the live client's
record and adds no regression against the native control. A similar error on
another client or version does not inherit the exception without evidence.

R1–R3 and R5–R10 remain mandatory. In particular, older recovery must preserve a
newer launch, uncertain observations stay pending, and actual exit must still
trigger cleanup. Terminal input, stop/resume, signals and exact exit-status
controls still run. A read-then-rename repair without ownership fencing is not
authorized by this exception.

Keep raw failing observations and the suspension diagnostic. Attribute a
qualified result as `KNOWN_UPSTREAM_LIMITATION`, separately from PASS, FAIL and
SKIP; do not turn the failing assertion into a pass or skip the scenario. Only
the independently attributed suspension identity loss is non-blocking. A local
regression, a failure of the safety controls above, or an unattributed failure
still blocks acceptance. Historical results are not automatically reclassified,
and this requirements change does not itself pass the implementation gate.

[Follow-up #383](https://github.com/Seigiard/my-mac-setup/issues/383) owns restoring
strict end-to-end tests and acceptance after the upstream fix is verified on the
supported Herdr build. Upstream issue closure alone does not remove this
exception or establish that the installed build is fixed.

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
how uncertainty is exposed. It must also set the measured recovery-latency budget
and, if polling is selected, its cadence. These are blocked design decisions,
not discretion to fill in while shipping the launcher.

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
5. Native and wrapped real-client controls for terminal input/output, interactive
   job control, Ctrl-C, termination signals, and exact exit-status propagation.
   Prove that an ordinary interactive Pi launch acquires its canonical alias,
   loads the adapter under the actual Pi PID, takes over lifecycle reporting,
   and remains reachable under that alias. Claim-isolation probes alone cannot
   approve a changed process tree.

Gate passes only with observed safe outcomes and a reviewed owner/protocol
addendum, accounting for the scoped exception above as a separate verdict.
A skip or a fake server is not a pass. If isolation cannot be proved,
keep runtime unchanged and return with the precise upstream API requirement or
the client-side registration alternative. Do not silently weaken R1 or R2.

## Implementation addendum — accepted baseline

The addendum was accepted with proof PR #382 at reviewed head
`14fdd99cbea55796d76eb470b9ae90f01607737a` and merged into the delivery branch at
`402f12eb0eb2f73e1225032b49726d429231b081`. It is the runtime implementation
baseline. The evidence note keeps proof acceptance separate from runtime checks
and deployed behavior.

### Owner and admission

- Use one narrow observer for each host-local recovery state root. On the proved
  macOS host, a user `launchd` job is its restart owner: `RunAtLoad` plus
  `KeepAlive.SuccessfulExit = false`. The actual SIGKILL/restart control passed;
  `KeepAlive.Crashed = true` did not restart that signal on this host.
- The proof-controller PID guard belongs only to disposable test jobs. The
  deployed observer must outlive a launcher or client and read durable intents
  after restart. Its readiness must be established before a new claim is made.
- Keep versioned recovery intents separate from legacy claim/rename markers.
  Failure to establish a proved restart owner or durable intent follows R10.
  Other restart hosts are not proved here; do not acquire new claims behind an
  unverified platform fallback. Independently valid existing aliases can still
  be reused without adopting their cleanup responsibility.
- An alias still covered by an unresolved intent on the same server and terminal
  is not independently reusable. For a confirmed-dead prior client, establish the
  observer and wait up to the healthy recovery budget before starting cci or the
  native client. Then read the alias again and use fresh admission if it is gone.
  Live or unverifiable prior ownership, or cleanup still pending at the bound,
  preserves bare native startup with a warning instead of borrowing the identity.

### Identity and ordering

- Persist server socket location and connected peer PID/start identity, stable
  terminal identity, launch generation, source, reserved sequences, and the
  observed process PID/start identity before acquiring the claim.
- Reserve ordered `N` (claim), `N+1` (handoff), and `N+2` (final release). Later
  generations must sort after all earlier reserved operations. Sequence
  allocation must remain monotonic across concurrent starts and clock changes.
  The candidate allocator persists its high-water mark under an inode-stable
  lock shared by launches using that source.
- Use a new protocol source, distinct from legacy `herdr-agent-intercom` claims.
  Fence each RPC to its connected server peer and verify the resulting state;
  neither a successful response nor a pre-read licenses an unconditional change.
  Herdr 0.9.1's acquisition rename is also unconditional: it cannot fence
  overlapping acquisitions in one pane by generation or process identity.
- Serialize acknowledgement, native binding, handoff and observation with the
  same inode-stable per-intent lock. JSON replacement alone is insufficient.
  Observer lock acquisition is nonblocking so a busy intent does not stop others.
- OpenCode and Pi keep their actual exec PID. For Claude, pass through cci's
  preliminary `--version` bridge call, then bind the real bridge PID before its
  native exec. Validate the live parent before that locked binding. A late bridge
  cannot revive a settled claim; preserve native argv without new enrollment.
- Retire on verified client takeover without mutating its authority. Claude's
  first-prompt handoff uses its reserved operation and native ancestry, preserves
  the alias, and needs a later concrete published agent state as confirmation.
  Persist the authorized request before its first RPC. The observer retries an
  unavailable handoff for that same live PID/start identity without another
  prompt. An acknowledged release still needs concrete state before retirement.
  Follow moved terminals by stable identity. A new server permits only read-only
  absence confirmation for the old obligation, never a stale mutation.
- Keep unavailable observations, unacknowledged acquisition, and ambiguous
  ownership pending. Age and suspension are not death. Keep diagnostics explicit
  and retries independent of another launch. This protocol does not repair the
  accepted upstream suspension identity loss with a read-then-rename operation.

### Terminal intent archive

The owner approved keeping completed diagnostics outside the active scan.
Pending and unresolved obligations stay active. Once a record is `settled` or
`retired`, move it into `intents/archive` under its existing lock. The observer
does not open archived records during its 100 ms scan.

Keep terminal receipts for at most seven days and at most 1000 records, checked
once per minute. Their original handles remain readable while retained. A late
bind or handoff refuses a terminal or expired obligation. Handles are never
reused. Only the initial writer creates an intent lock; later callers open the
existing inode. After durable archival the sidecar can be removed: queued
callers retain the old inode and observe terminal state, while new callers
cannot create a replacement lock. Sequence and owner-admission locks remain
persistent and are outside this retention policy.

### Recovery budget and evidence

The healthy-state target is verified recovery within **10 seconds** of confirmed
client exit, with the observer available, successful local identity/Herdr reads,
and known ownership. Poll at **100 ms**; retry an uncertain acknowledged release
no more often than every **2 seconds**. A missed healthy budget fails acceptance;
an unavailable observation stays pending rather than being called success.

The registered ten-claim burst control measures verified absence after exit
observations. The evidence note below is the single index of current artifacts
and measured latency. These measurements cover representative workloads, not
arbitrary load.
The final runtime must meet the same budget and repeat the representative burst
control; retain measured latency separately from hang-guard timeouts.

The checked-in [evidence note](../solutions/architecture-patterns/intercom-claim-recovery-ownership-proof.md)
names the owner/client runs, direct or recovery-disabled baselines, no-live-
mutation calibration and cleanup receipts. Known upstream outcomes are distinct
from PASS and remain governed by the exception above and follow-up #383.

## Verification ownership

The consumer is a person or automation reading Herdr state after a failed launch.
The independent oracle is real client exit plus Herdr's resulting record and
authority, including a real surviving successor. Permanent tests should protect
the repository-owned cleanup transitions, not encode another copy of client
argument grammar. Extend the existing launcher/release cases in
`tests/bashunit/scripts_test.sh`; keep live conformance skips visible.

Acceptance includes invalid Pi input with both a valid utility control and a
valid claim-producing interactive Pi control, normal exit,
termination before first report, non-TTY Pi, no-prompt live clients, real takeover,
delayed old cleanup, lost observation and recovery-owner restart. It also includes
the real-client terminal/signal/exit controls above. Prove that cleanup runs when
no second client is launched. A regression that deletes the newer record must
turn the isolation check red; a bypass that silently disables supported Pi
enrollment must fail the interactive control.

Apply `docs/agent-verification.md` to the final implementation. New managed paths
or deployment-dependent lifecycle behavior require `make test-ubuntu`. Ubuntu
and macOS CI must pass before merge. The managed runtime and its opt-in
conformance probes are implemented together; acceptance requires both layers.

## Runtime implementation and remaining acceptance

- Implemented in draft PR #387: the shared recovery engine, launcher and Claude
  bridge, launchd owner, durable intents, takeover and archival. The #378 fresh
  and used-pane paths remain distinct.
- The agent-read contract and ADR-0018 describe the runtime, legacy boundary and
  pending diagnostics. The evidence note records behavioral and live checks.
- #384 owns the reproduced old-claim/new-Claude alias race and its regression
  fix. An unresolved recovery claim is not an independently reusable alias.
- #385 owns the remaining first-review repairs and their verification.

The final acceptance checklist lives in #377: complete cumulative review and
confirming rounds, final-diff checks, exact-head runtime acceptance, then epic
integration, CI and a live demonstration. Keep #387 draft until that runtime
acceptance is complete. PR #381 remains the final delivery PR; the owner decides
its merge to main. Implemented and locally checked does not mean deployed.
