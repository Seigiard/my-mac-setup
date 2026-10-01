# Intercom recovery engine interface

Accepted design for #389, #392, #393 and #394. Ownership boundaries are accepted
in [ADR-0022](../decisions/0022-centralize-intercom-admission-in-the-recovery-engine.md).
The owner confirmed the complete contract on 2026-10-01. Implementation is pending.

## Admission result

The request contains `state_root`, `socket_path`, `pane_id`, `agent_kind` and
`launcher_pid`. The engine obtains the launcher's start identity through its host
dependency, checks ancestry and rechecks identity before acquisition.
`--launcher-start` is removed rather than asking callers to format identity.

Two independent fields describe startup and the remaining recovery obligation:

- `launch`: `enrolled(alias, route)` or `native(reason)`.
- `recovery`: `none` or `intent(handle)`.

Enrollment routes are `claimed`, `reused` and `deferred_rename`. A native result
may retain an intent after an uncertain acquisition. Its handle does not authorize
enrollment. Existing-alias reuse and deferred rename need no new claim.

The Python result is structured. The shell result is one versioned TSV record
with six fields: `v1`, `launch_kind`, `route`, `alias_or_dash`,
`intent_id_or_dash` and `reason_code`. Fields are validated single-line values;
absent values use `-`. Detailed diagnostics go to stderr. Bash reads the record
with its built-in `read`, without JSON subprocesses or `eval`.

Expected native fallback returns exit status 0. Invocation errors return a
nonzero status. A failed invocation or malformed result makes the launcher use
native startup without inherited enrollment. Any durable intent already created
remains the observer's responsibility.

## Public operations

The CLI exposes `admit`, `observe`, `bind-exec` and `handoff`.
Owner readiness, alias reuse and individual acquisition attempts are internal.
The Python interface exposes one observation step shared by CI scenarios and
the observer loop.

The native Claude leaf owns argv reconstruction. `bind-exec` validates and binds
the native process, selects the permitted execution path and delegates to that
leaf. It does not reconstruct native argv itself.

## Lifecycle state

Phases remain `intent`, `acquired`, `settled` and `retired`. Pending is an
observable unresolved condition, with a structured reason and a next-attempt
deadline where applicable. It preserves whether acquisition was acknowledged.
Diagnostic text explains state rather than encoding it.

One transition function owns phase changes, waiting metadata and archiving.
Settlement ends the owned cleanup obligation on confirmed evidence. Retirement
ends the obligation without cleaning up a successor or replacement owner, on
sufficient evidence that the old responsibility can end.

## Observation step

On an engine configured with its state root, `observe_one(intent_id)` returns an
`Observation`: current phase when known, step outcome, machine-readable
`reason_code` and next-attempt deadline when scheduled.

Outcomes are `waiting`, `settled`, `retired`, `busy` and `unavailable`.
`waiting` preserves the `intent` or `acquired` phase. `busy` reports lock
contention without waiting, so the observer can continue to other intents.
`unavailable` reports an inaccessible handle, including one whose archive was
pruned; it does not imply settlement. A busy or unavailable result does not
invent a phase it could not read safely.

Repeated calls return the terminal result while the archive exists. Pruned
handles are never recreated. CI scenarios and the observer loop use this same
operation rather than inspecting the private persistence schema.

## Host identity

The canonical start token is whitespace-normalized `ps lstart` output obtained
with `LC_ALL=C` and `TZ=UTC`. Process identity is PID plus start token. Newly
persisted records identify their format version. This retains the precision of
`ps lstart`; it does not claim a stronger kernel identity guarantee.

Legacy compatibility has low value for this two-machine local project. A broad
migration layer is not a goal. Unknown legacy identity must still not be treated
as proof of exit.

## Fake and real adapter evidence

Engine scenarios use a fake adapter to exercise retries, successor preservation,
unknown evidence and controlled event ordering. Scheduling points can delay
application, apply a request without delivering its response, and replace the
server between requests.

These scenarios do not prove transport fencing. Real adapter checks and live
probes verify peer identity on the descriptor used for the request and calibrate
the fake's Herdr semantics. ADR-0021's live gate remains independent.

## Rollout

The owner accepts stopping all participating clients on each of the two machines
for a coordinated update. Let the old observer finish recovery and resolve any
remaining pending obligations before switching versions. Update the engine,
callers and launchd configuration together, restart the observer, then start new
clients.

Old CLI flags and path-based handles need no compatibility layer. Preserve and
report any unsupported records encountered; incompatibility is not evidence
authorizing cleanup.

## Confirmation

The owner confirmed all decisions above as the implementation contract for
#389, #392, #393 and #394 on 2026-10-01.
