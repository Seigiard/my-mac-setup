---
title: Intercom claim recovery ownership proof
date: 2026-09-29
category: architecture-patterns
module: herdr-agent-intercom
problem_type: architecture_pattern
severity: high
status: in-progress
applies_when:
  - Implementing or reviewing failed Intercom launch recovery
  - Checking durable claim ownership across process exit and suspension
tags:
  - intercom
  - herdr
  - process-identity
  - ownership-proof
---

# Intercom claim recovery ownership proof

## Boundary

The owner accepts the
[scoped upstream suspension exception](../../plans/2026-09-29-intercom-claim-recovery-spec.md#accepted-upstream-suspension-exception).
Proof PR #382 passed its confirming review and merged into the delivery branch
at `402f12eb0eb2f73e1225032b49726d429231b081`. Runtime verification now executes
the managed launcher, bridge, release command, shared engine and rendered
launchd job from private staging. This is not a host rollout or final delivery
acceptance. Historical proof results below remain unchanged.

### Runtime verification checkpoint

Artifacts live under `~/.claude/artifacts/377/`. The runtime uses the shared
engine at `home/dot_local/lib/intercom-claim-recovery.py`; the former prototype
module is a test shim that loads this same engine.

### Repairs after draft checkpoint #387

Issues #384 and #385 track this batch. The alias-reuse race was reproduced on
checkpoint `078b06e`: old cleanup removed the Herdr alias while the successor
kept that name in the private broker. The stable regression barrier is at CCI's
Node entry, after alias selection and before CCI starts. A native-exec barrier
was too late because CCI itself could already become detectable. The permanent
case failed at `reuse-successor-identity` in `runtime-check-race-red104.log`.

The reuse guard now waits for confirmed-dead obligations on the same server and
terminal to settle, then rereads the alias. Live or unverifiable prior ownership
falls back to native startup without borrowing its identity. Both orderings and
the live/unverifiable controls passed in `runtime-check-race-green106.log`;
`runtime-check-reuse-read107.log` covers stale readback and an independent alias.

Current cumulative evidence:

- `runtime-check-owner109.log`: 18 PASS, owner-only exit 3, cleanup complete.
  Artifact `ownership-proof-eef4ed5d8f7442e383d843b274619c2b.json`.
- `runtime-client-116.log`: 30 PASS and three KNOWN_UPSTREAM_LIMITATION rows,
  no FAIL/SKIP/UNVERIFIED, cleanup complete. Artifact
  `client-proof-d5aff934ae28483b9dac3bc507e54f54.json`.
- `runtime-check-deploy113.log`: canonical `make test-ubuntu` passed with the
  Python dependency moved to the full macOS Brewfile. Later edits only affect
  live suspension measurement. Focused launcher checks passed 13 cases and 195
  assertions; general Python checks passed 42 tests; lint passed.
- `runtime-restart-calibration-108.json`: a staged restart-policy mutation
  passed admission and failed at the restart assertion; restored code passed.
- `suspension-safety-calibration-115.json`: live-release and live-rename mutants
  failed their safety guards; restored code qualified only the upstream loss.

The failed client110 and client112 runs remain recorded. Client110 exposed a
non-atomic readiness marker in the new fixture; it now uses `atomic_write`.
Client112 compared immediate post-fg snapshots at different detection phases.
`opencode-resume-diagnostic-114.json` observed this transient in the control too.
OpenCode now records the first snapshot, waits for Herdr redetection in both
routes, and records the wait and the same resumed PID/start identity. The bound
is an observation hang guard, not a latency-equivalence assertion.

Suspension loss and its exception qualification now use the same comparison
baseline: a recovery-disabled reference with the matching status driver for
OpenCode/Pi, and direct native Claude. Separate direct-native observations and
raw assertions remain in the artifact. The accepted contract permits native or
recovery-disabled evidence; no live mutation, foreign identity or unqualified
loss is accepted. Final cumulative review remains outstanding.

### Earlier runtime checkpoints

The owner-requested post-review batch is tracked in
[#377's checklist](https://github.com/Seigiard/my-mac-setup/issues/377#issuecomment-5914791500).
Terminal intents now leave the hot scan for a bounded archive. The sidecar
protocol lets queued callers finish on the original inode and prevents new
callers from recreating it. The archive policy is in the specification.
Evidence at that checkpoint:

- `runtime-check-owner97.log`: 18 PASS, owner-only exit 3, with cleanup.
  Artifact `ownership-proof-c054422872c54e3aa256c195932d3860.json`.
- `runtime-client-100.log`: 28 PASS and three independently qualified
  KNOWN_UPSTREAM_LIMITATION rows, no FAIL/SKIP/UNVERIFIED, with cleanup.
  Artifact `client-proof-03b8a17f51344d93b10842b0eaa8a77d.json`.
- `runtime-check-deploy99.log`: canonical `make test-ubuntu` passed on the
  final deployment-relevant files. `make test-python` passed 42 tests after the
  lock-contention assertion was strengthened. Lint and diff checks passed.
- `restored-test-calibrations-95.json`: the restored collision retry failed
  when retry was disabled; PTY Pi utilities failed without their guard and
  passed with it restored. The normal-order collision case uses real Herdr.
- `archive-calibrations-96.json`: disabling archival, recreating a removed
  lock, and disabling retention each failed their intended assertion; the
  restored archive suite passed. The separate contention test observes a real
  failed flock attempt before moving the record.

The failed client98 run is retained. Its collision control left an owned alias
occupied into later cases; the fixture now closes that control pane after its
preservation assertions. At that checkpoint the alias-reuse reproduction was
still pending. The later reproduction and fix are recorded above. The initial
runtime review did not confirm this batch.

Earlier runtime checkpoints:

- `runtime-check-owner82.log`: 18 owner controls passed. Exit 3 denotes the
  separate client gate, not an owner failure. Artifact:
  `ownership-proof-2bf5f6ab37744d8f86349b4d8e386aec.json`.
- `runtime-client-82.log`: 24 PASS and three independently qualified
  KNOWN_UPSTREAM_LIMITATION rows, with no FAIL, SKIP or UNVERIFIED rows. Artifact:
  `client-proof-81bbc8f94caf4518916234a74542edb6.json`.
- `runtime-client-90.log`: the cumulative runtime gate passed with 27 PASS and
  three KNOWN_UPSTREAM_LIMITATION rows, no FAIL, SKIP or UNVERIFIED rows, and
  complete owned cleanup. Artifact:
  `client-proof-124aeba2e4ff4028820abe86472890f2.json`.
- `runtime-check-legacy83.log`: the actual legacy release preserved a new
  Claude runtime successor, including its private Intercom registration.
- `runtime-check-partial87.log`: a real rename with a lost response preserved
  native startup, removed inherited enrollment authority, retained durable
  correlation and left no claim after client exit. The relay's ordinary-response
  control completed enrollment. Unacknowledged absence may remain pending.
- `runtime-check-restart88.log`: stale readiness was replaced before admission;
  launchd restarted the killed production observer, which recovered client exit.
- `runtime-check-deploy83.log`: `make test-ubuntu` passed. The first attempt
  exposed a fixture's ambient `herdr-peer-alias` dependency; the fixture now
  stages that helper explicitly and keeps its original assertions.
- `make test-agent-intercom-loaders`: 14 PASS. `make lint` passed after the
  runtime test additions.
- `runtime-check-red91.log`: removing inherited-name cleanup from the private
  staged launcher made the partial-acquisition test fail at
  `partial-native-authority`. Raw artifact:
  `runtime-red-inherited-identity-7f9fa4f7b656418a80f1bcca182c8e24.json`.
  The earlier concurrent calibration attempt (`red89`) failed in its cleanup
  control instead and is not regression evidence. The sequential run reached
  the intended failure. Other new runtime cases have green observations but no
  new mutation calibration yet.

The complete client run used Herdr 0.9.3, Claude 2.1.280, OpenCode 1.18.30 and
Pi 0.87.1. OpenCode and Pi retain an independent suspension baseline plus a
recovery-disabled reference control with the same foreground status driver.
Raw alias-loss assertions remain FAIL in the qualified evidence.

Runtime review and delivery acceptance remain outstanding.
Docker skips include platform-specific macOS checks, the opt-in live Codex
account query, Herdr checks requiring a running caller session, and external
client settings checks without the required installed client/model catalog.
Those skips are not proof of the skipped behavior.

### Full-review repair evidence

The revised owner command completed with **18 PASS**, exit **3**, in
`ownership-proof-83d9bbf6efef47608b588848cc19b845.json`. The ten-claim burst's
slowest verified absence was **4.794 seconds**, rounded up. Cleanup removed its
owned session tree. This verdict covers owner controls, not the client gate.

The allocator control uses real Herdr after a backward clock step: a newer
same-source claim must survive the older launch's reserved release. The former
wall-clock-only algorithm fails that same control with exit 1
(`ownership-proof-d74a943a09464dd2b9d010f075dc435a.json`). Separate processes
check persistent ordering and four non-overlapping three-operation reservations;
the assertions permit gaps between reservations.

Rerun only this control with the owner command's `--case allocator-controls`.
Add `--allocator-implementation legacy` for the expected-failing calibration.
The ordinary owner command includes the shared-allocator control by default.
The revised client command completed with **24 PASS** and **3
KNOWN_UPSTREAM_LIMITATION**, exit **0**, in
`client-proof-052038c585ae4787a25ab370c9dfe5ca.json`. Its 27 cases include initial
admission failure, late Claude binding refusal, unrelated and nested native
handoff refusal, and retry after a real first-prompt socket outage. The retry
case observes a release by the observer PID after socket restoration, without a
second prompt. The client run removed its scratch directory and isolated server.
Versions were Herdr 0.9.1, Claude 2.1.277, OpenCode 1.18.30 and Pi 0.87.1.

Admission controls cover a non-directory intent path and unavailable server
or launcher process identity. Diagnostic receipts reuse only an identity already
observed before the failure; they do not repeat the failed lookup. A real exec
control verifies that fallback clears inherited `OPENCODE_INTERCOM_NAME`, which
the managed adapter consumes. A fresh-pane `agent_name_taken` control verifies
partial acquisition, native startup, durable correlation and the other alias
owner's preservation. Native exit can clear the record before recovery observes
it; the unacknowledged local obligation then remains pending under R5 rather
than treating absence as an acknowledgement.

The utility control audits actual Herdr CLI calls through an exec-forwarding
recorder; the installed server supplies every response. A screen-detected,
unnamed native utility record is not itself a launcher claim. The control
rejects enrollment mutations and new durable intents. The final runtime task
must replace the reference-launcher entry with its actual managed entrypoint.

Suspension evidence now requires the wrapped alias before Ctrl-Z, equal native
and wrapped stop mechanisms, matching observed loss shapes, and no additional
identity loss after resume. A re-detected unnamed record where the baseline has
none is not additional loss. Foreign names, kinds or terminal identities fail.
Samples start at observed suspension before waiting for the observer. Elapsed
times are diagnostic: independently scheduled runs do not establish a numeric
latency-equivalence contract. The separate healthy cleanup budget still applies.
Pi retains its independent, recovery-disabled reference baseline and also uses
a recovery-disabled reference control with the same status-driver process tree
for the shape comparison. Both observations remain in the artifact. This keeps
the fixture's extra foreground process from being attributed to recovery.

Isolated regression calibrations reached their intended failures:

| Removed behavior | Regression evidence |
|---|---|
| Observer retries authorized handoff | `handoff-retry-mutant-1c6866bdf4bd4b7091f2cb61e3fcaf7c.json` |
| Non-descendant handoff refusal | `handoff-non-descendant-mutant-62b174b4f1874599a3b558efa7adadbd.json` |
| Nested native handoff refusal | `handoff-nested-mutant-664852d7d9264141b50653779395fbae.json` |
| Initial admission preserves native startup | `admission-initial-mutant-4610b3a8dd77465cbfeb0be8e75acf6d.json` |
| Late binding preserves native startup | `admission-late-mutant-7efca10f8c614bdab10e16c0f6d8a808.json` |
| Known Pi utility bypass | `utility-classification-mutant-1a35837cf3714921a2f5e0dd9f802811.json` |
| Wrapped Ctrl-Z reaches the client | `job-control-mutant-e5db52c14b064b319708f23be0259e25.json` |
| Recovery leaves a stopped live client registered | `qualification-live-release-mutant-3478c97971154b82bf2bc4155cd50145.json` |
| Recovery never renames that live client | `qualification-live-rename-mutant-89a53da71be241dda3cd3ac5e18fb5ba.json` |
| Admission catches identity-reader failures | `admission-recovery-error-mutant-302ecd1ad7e74ec18db2c7d13b52eb65.json` |
| Diagnostic receipt does not repeat a failed own-PID lookup | `admission-receipt-identity-mutant-469592817ed14b62978a9508715b1e8e.json` |
| Partial admission retains pending correlation | `admission-pending-receipt-mutant-558f2ad4a5cf4b39b01c517f7b0eeb85.json` |
| Fallback clears inherited OpenCode identity | `admission-focus-7945a54f7de24426a801b664cacd251a.json` |

The positive sides ran in the complete client command above. These artifacts
record failed guards, not additional passing client cases. A confirming full
review of the changed protocol and checks remains outstanding.

### Observed Herdr limitation

The suspension diagnostic starts native Claude directly, with no `cci`, no
terminal status driver, and the recovery observer confirmed stopped. It waits
for the real input prompt, assigns a pool alias, then sends Ctrl-Z. The native
PID and start identity remain unchanged and its process state is `T`, but
Herdr removes the alias and agent record. `fg` resumes that same native process
without restoring the alias.

`suspension-proof-1790719684444367000.json` records this independent control.
The earlier wrapped control, `suspended-claim-aa33a4e4052e425ba59f3732b763b320.json`,
shows the same loss while its recovery observer is stopped. Both runs cleaned
their owned clients, server and private state.

Checked restoration paths do not close the gap:

- `pane.report_agent` returns `ok` for the stopped terminal but publishes no
  record, both with the old sequence and with a fresh sequence.
- `agent.rename` then returns `agent_not_found`.
- The bundled `AgentRenameParams` schema has only `target` and `name`. A rename
  after resume has no expected-generation or process-identity precondition, so
  using it to repair an old launch can overwrite a newer launch's alias.
- `pane.report_metadata` changes presentation, not the canonical agent name.

Herdr 0.9.1 has a [name-clear path after exit observation](https://github.com/herdrdev/herdr/blob/v0.9.1/src/terminal/state.rs#L577-L584)
and [rejects custom claims after that observation](https://github.com/herdrdev/herdr/blob/v0.9.1/src/terminal/state.rs#L650-L659).
The live stopped-process trace observes both effects; it is not evidence that
the process actually exited.

The approved exception permits this independently attributed upstream behavior
without permitting recovery to release or rename a live client or a newer
launch. Each client/build needs its own attribution and local-safety evidence;
the direct-Claude control alone does not qualify OpenCode's failure. See the
specification for the acceptance rule. [#383](https://github.com/Seigiard/my-mac-setup/issues/383)
tracks restoring strict end-to-end retention after a verified Herdr fix. The
prototype does not attempt an unsafe read-then-rename repair.

The owner probe runs installed Herdr 0.9.1 in an isolated named session. A
temporary macOS `launchd` job in `gui/<uid>` restarts the observer with
`RunAtLoad` and restart-on-failure `KeepAlive`. A proof-controller PID/start guard
unregisters the temporary job when that controller exits. This is a harness
abandonment guard, not the eventual deployed service lifetime. Each job has its
own plist, logs and PID receipt. Teardown
boots it out and confirms process exit before deleting its files. Cleanup
failures preserve available scratch state for diagnosis; removal errors fail
the verdict rather than being ignored.

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

Herdr 0.9.1 exposes neither a conditional rename nor claim source/sequence in
`agent.get`. The initial acquisition rename, like the explicitly declined
post-suspension repair, has no generation or process-identity fence. This proof
does not claim to make overlapping same-pane acquisitions safe; the normal pane
foreground-launch boundary makes that window narrow, but it is not an atomic
Herdr guarantee.

### Claude's native process and first prompt

`cci` probes its configured bridge with `--version` even in MCP mode. That
short-lived process is not the interactive client. The proof bridge passes the
utility through, then validates that the real before-exec bridge descends from
its recorded live launcher. Binding can finish under the lock after that parent
exits. The bridge and native exec share a PID.
Binding uses the same lock as cleanup. A bridge arriving after settlement
starts the native argv without cci's generated enrollment rather than reviving
the old claim.

The real first-prompt hook checks native ancestry and stable terminal identity.
It requests a source-scoped, reserved-sequence release. The client probe reserves
`N` for acquisition, `N+1` for handoff and `N+2` for final cleanup. Only a later
published concrete agent state retires the intent; a successful release response is
not the handoff verdict. The probe also requires the same alias and a live native
client. Input readiness is a positive `live_prompt_box` rule, separate from the
published lifecycle state being tested.

`handoff_intended_at_ns` is diagnostic intent written before the RPC. It is not
an acknowledgement and is never used as a retirement predicate.

The proof uses Python 3.14.7. Its monotonic clock is shared by the hook and
observer processes ([Python's documented contract](https://docs.python.org/3.14/library/time.html#time.monotonic)).
Handoff retry consults that deadline only for the same live client incarnation.
A host reboot ends that client; dead-client cleanup does not read the handoff
deadline. An observer-process restart preserves the clock. The runtime must
retain this shared-clock property; macOS requires Python 3.10 or later.

## Owner evidence

The current registered owner cases are:

| Case | Observed result |
| --- | --- |
| Native binding versus cleanup | A barrier pauses binding after its live-parent check. The launcher dies, an observer attempts cleanup, and the lock preserves the claim. The bound child then owns recovery until its own exit. |
| Late native binding | A fresh bridge cannot adopt an exited or settled launch or change its durable record. |
| Failed process lookup | Failure is limited to the selected client's reader. The live claim remains; actual exit releases it. Server-peer reads still work. |
| Observer restart | `launchd` restarts a killed observer. Distinct old/new PID receipts are recorded, and the new process consumes the same intent. |
| Proof-controller exit | The temporary job unregisters itself and its observer exits when the controlling PID/start identity ends. |
| Same-source successor | Reserved old release preserves a newer same-source working record and alias. The successor's own release removes it. |
| Concrete successor state | Bookkeeping retires while the original process is alive, without releasing or renaming the successor. |
| Moved pane | Cleanup follows the same terminal under its current coordinate. |
| Fenced old release | A post-response trace proves the delayed release ran before the successor-preservation assertion. |
| Unknown successor | The newer unknown record survives. Unavailable ownership evidence remains pending rather than being invented from RPC success. |
| Socket outage and PID incarnation | Restoring the socket resumes cleanup. A process-reader seam models a different start token for the same real PID; the replacement stays alive. This is not a claim of actual kernel PID recycling. |
| Acquisition crash windows | Presence is confirmed before cleanup, including a delayed acquisition and a claim whose acknowledgement never happened. |
| Source-scoped clear alternative | Clearing authority on a renamed claim leaves an alias-only unknown record; it cannot implement failed-launch cleanup. |
| Pending managed successor | A real `herdr agent start` reaches its pre-exec barrier. Old release preserves the reserved alias and terminal. The pane is closed before the unused native launch begins. |
| Concurrent and repeated cleanup | Both observers reach an entry barrier and attempt the same intent; cleanup converges on a settled obligation. Repeated release and closed-terminal replay also settle safely. Lock sensitivity belongs to the separate binding case. |
| Server restart | The old record is confirmed absent after restart, and a new server's unrelated named record remains unchanged. |
| Healthy recovery budget | Ten live claims are first confirmed present, then their real processes exit. Batched Herdr agent-list observations confirm each claim absent within the ten-second target. |
| Sequence allocation | A backward clock step cannot let old release remove a later claim. Separate processes retain ordering and reserve non-overlapping triples concurrently. |

Calibration found and closed a false-green timing window in the new binding
case. Its observer witness now requires an attempt that **started** after
launcher exit. Removing the lock then deletes the live child's claim and makes
the case fail; restoring it passes. A separate in-process mutation that treats
any live PID as the same incarnation fails the same-PID/different-token case;
PID plus start identity passes. The failed-client-reader regression was also
observed red and green with server-peer lookup left functional.

## Real-client evidence and remaining work

The current owner and client receipts are indexed under **Full-review repair
evidence** above. The standalone native diagnostic retains its raw failing
assertions. Reference-launcher utility classification is compatibility evidence;
R8 on the candidate's managed admission entrypoint remains for task 377-2.

The qualified baselines differ explicitly:

- Claude and OpenCode: direct native launch, no cci or status driver, observer
  confirmed stopped; same live PID/start identity across suspension/resume.
- Pi: the unmodified launcher from merged #378, with recovery disabled and the
  same upstream Herdr integration. A bare Pi renamed after session attachment
  retained its name, so that different naming baseline was not used to excuse
  the wrapped loss. The reference launcher also lost its early-assigned name
  after verified Pi lifecycle takeover. The qualified client run records the
  matched lifecycle phase and reference commit. A second reference control uses
  the wrapped fixture's status driver for the direct shape comparison, with
  recovery again confirmed stopped.

Each wrapped case observes stopped/live process identity and resumed input;
normal quit independently requires observed status 0 on each side. OpenCode
and Claude also witness the observer examining a pending intent while stopped.
Pi's intent has retired after lifecycle takeover, so its row proves suspension
attribution for that retired state, not pending-claim cleanup behavior.
The trace checks reject recovery mutations before quit. Append-only mutation
attempts are recorded on the fenced descriptor before sending the RPC, so a lost
response cannot hide a write. A native baseline that retains identity cannot
excuse wrapped loss. A fully retained wrapped identity is PASS, not a permanent
exception based only on a version string.

Calibration rejects real bad operations: the live-release and live-rename mutants
produce FAIL, not KNOWN_UPSTREAM_LIMITATION. The release control handles an early
bad release that settles the intent before the next observation can start.
Raw errors and native baseline evidence remain in the artifact.

The live detected-successor case now drives a real Claude past first-prompt
handoff, then performs delayed and repeated old release with no remaining hook
authority. The named record, session reference, live process, and real private
Intercom broker session ID/name survive unchanged.

The fixture gives the isolated Herdr client its own controlling terminal and a
160-column, 40-row PTY. Merely redirecting stdio left `/dev/tty` attached to the
runner and caused six-row readiness failures. Resume waits for the shell's empty
prompt, then for native raw-mode input readiness. Pi quits with Ctrl-D; `/exit`
can autocomplete a skill. Claude's owned inbox-monitor exit confirmation is
handled explicitly. Cleanup failure makes the saved gate verdict fail.

The ten-claim burst in `owner-budget-5c20d93e2bb94ce5aafc142bb7815f53.json`
verified all claims absent within a conservative 5.019-second maximum. The
proposed addendum sets a 10-second healthy target, 100-ms observation cadence,
and 2-second retry spacing for uncertain acknowledged release. The runtime
implementation must repeat that measurement. No runtime has been deployed.

### Historical owner and client results

These artifacts are superseded checkpoints, not current gate receipts:

- `ownership-proof-c70cca5b3fc24561855a2ba1b13a25c6.json`: sixteen passing owner
  cases, 0.926 seconds of observed recovery latency, including the
  unacknowledged-claim window and calibrated binding race.
- `ownership-proof-e70dc9f4be734b86a82c07d43679a055.json`: seventeen passing owner
  cases, including the ten-claim budget control at a 4.827-second maximum.
- `client-proof-47a9c136573f49769068d4ee30bfb939.json`: eighteen PASS and three
  KNOWN_UPSTREAM_LIMITATION rows, before the additional admission and handoff
  controls were registered.

`client-proof-4e8de3e25f634d9a8f9ead38205fbe54.json` records twenty client
controls: eighteen passed, while OpenCode and Claude lost enrollment during
suspension. Pi's print, normal quit, Ctrl-C, TERM, tool identity and stop/resume
controls passed. Claude and OpenCode normal quit and signal comparisons passed.
The later owner-only run covers the temporary job's restart-policy correction;
the client run did not kill that observer and does not supply restart evidence.

`bound-claude-11c940c973734532a536c8e1cace2d14.json` records real native Claude
survival across cci `SIGKILL`, retained-alias first-prompt handoff, and normal
`/exit`. These controls use an isolated bridge and settings file. They do not
claim that the deployed launcher already implements recovery.

The client probe stages the launcher from merged PR #378 at
`dc33b385891fdab07af303037cc1ad2e3e161471`, with only the candidate bridge entry
changed. Real clients retain PTY streams through a status-recording driver.
The pane shell survives client exit, so claim cleanup cannot pass merely because
the terminal disappeared. Read the latest native/wrapped print, signal and
job-control outcomes from their named artifacts. Qualified upstream suspension
loss can be reported separately under the approved exception; local regressions
and unattributed failures remain blocking. These older runs are not a new gate pass.

## Rerun and verdicts

```sh
MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_ownership_probe.py

MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_client_probe.py

MMS_LIVE_HERDR_OWNERSHIP_PROBE=1 \
MMS_LIVE_HERDR_OWNERSHIP_EVIDENCE_DIR="$HOME/.claude/artifacts/377/proof" \
python3 tests/helpers/intercom_claim_client_probe.py --suspension-diagnostic
```

These commands require a Herdr-managed caller and create only owned resources.
The owner command returns `1` for failed cases or cleanup, `2` for refusal, and
`3` when its cases pass but the separate full client gate remains unverified.
Read the UUID-named JSON artifact for the exact executed case set. A focused
calibration is not evidence that omitted cases ran. The client command returns
`0` only when every registered client case is either `PASS` or an independently
attributed `KNOWN_UPSTREAM_LIMITATION`; it returns `1` for any `FAIL`, `SKIP` or
`UNVERIFIED` row. Read the artifact counts for the PASS-only total. It does not
replace owner evidence or the required reviewed addendum.

The suspension-only command intentionally returns `1` on the observed Herdr
limitation. Its JSON includes the live stopped PID/start identity, alias loss,
checked API responses, and observer-disabled control. Keep that failure visible.
