---
title: Herdr Lifecycle Subscription and Restart Constraints - Research
type: research
date: 2026-09-18
topic: herdr-subscription-constraints
status: complete
execution: none
---

# Herdr Lifecycle Subscription and Restart Constraints - Research

## Scope And Resolution

This resolves [issue #288](https://github.com/Seigiard/my-mac-setup/issues/288),
the research ticket under [map #285](https://github.com/Seigiard/my-mac-setup/issues/285).
It investigates the installed Herdr 0.9.0 binary, the versioned 0.9.0
documentation and source, and the repository's resource-tree and child-lifecycle
implementation. It does not implement a supervisor.

**Resolution:** a durable supervisor must be a long-lived raw-socket client that
reconnects and rebuilds its view from `session.snapshot`; it cannot obtain a
lossless restart stream from Herdr 0.9.0. The startup ordering is prescribed:
subscribe on one connection, wait for the acknowledgement, buffer events, take
the snapshot on another connection, install it, and apply the buffered events in
order. A disconnect or server restart loses every transition not observed by the
subscriber. The resource-tree foundation from PR #283 supplies server-scoped
provenance and Agent parentage, but it is not an event ledger and does not close
that loss window.

## Evidence Cut

The installed binary was queried on 2026-09-18:

```text
$ herdr --version
herdr 0.9.0

$ herdr api --help
Commands: snapshot, schema

$ herdr agent --help
Commands: list, get, read, send-keys, prompt, rename, focus, wait, attach, start, explain
```

`herdr api snapshot` returned `version: 0.9.0`, `protocol: 22`, and the
snapshot keys `agents`, `focused_pane_id`, `focused_tab_id`,
`focused_workspace_id`, `layouts`, `panes`, `protocol`, `tabs`, `version`, and
`workspaces`. `herdr api schema --json` returned protocol 22, schema version 1,
the five Agent status values `idle`, `working`, `blocked`, `done`, and `unknown`,
and the subscription event kinds `pane.output_matched`,
`pane.agent_status_changed`, and `pane.scroll_changed`.

The durable versioned sources used below are the Herdr 0.9.0 tag. The local
source and test references point at the repository branch containing this
research artifact.

## Findings

### 1. Subscription acknowledgement ordering

The documented bootstrap protocol is exact:

1. Open `events.subscribe` on a separate connection.
2. Wait for its first response, which acknowledges the subscription.
3. Buffer the event stream while calling `session.snapshot`.
4. Install the snapshot.
5. Apply buffered events in order, then continue streaming.

This is the documented way to avoid a bootstrap gap, not an implementation detail
that a client may reorder. `session.snapshot` is a one-time bootstrap response,
not a subscription. [H1]

The 0.9.0 server writes the `subscription_started` success response only after
it has constructed the requested subscriptions. It then keeps the socket open
and polls them. For ordinary lifecycle subscriptions, the server captures an
internal start sequence before constructing the subscription, so events emitted
during setup are eligible for delivery after the acknowledgement. [H5] [H6]

The subscription and snapshot are not one atomic server transaction. The client
must provide the consistency boundary by keeping the subscription connection
alive, buffering its events, and applying them after the snapshot. A client that
takes a snapshot first can miss an event between the snapshot and subscription.

### 2. Replay, current-state setup, and the loss window

For lifecycle subscriptions, Herdr 0.9.0 starts at live events when the request
is accepted. It does not replay lifecycle events retained before that point.
This behavior was released as the fix for upstream issue #1270; that issue's
accepted expectation explicitly says historical replay requires an explicit
cursor or replay parameter. [H4] [H10]

There is an important status-specific distinction:

- A `pane.agent_status_changed` subscription can be filtered by pane and an
  optional target status.
- During setup, Herdr probes the current pane. If the requested status already
  matches, the subscription can emit one current-state event after the
  acknowledgement.
- That current-state event is not replay of a historical transition. It is a
  fresh observation of the current pane state.
- `events.wait` similarly can return an initial current status match, but it is a
  one-shot wait, not a replay or recovery cursor.

The source tests name these cases: `lifecycle_subscription_skips_history_but_keeps_setup_window_events`,
`agent_status_subscription_prefers_setup_window_events_over_initial_snapshot`,
and `events_wait_agent_status_returns_initial_match`. [H6] [H5]

Herdr's internal `EventHub` retains up to 512 events while the server process is
alive and numbers them internally. That does **not** create a public replay
contract: the subscription response contains only an event kind and data, and
the request has no `since`, cursor, or replay field. A reconnecting client cannot
ask for the events it missed, even if the server's internal buffer still happens
to contain them. [H7] [H8] [H10]

The public status event also carries no event ID, event sequence, timestamp, or
server incarnation. Its required fields are only `pane_id`, `workspace_id`, and
`agent_status`; `agent`, `title`, `display_agent`, and `state_labels` are
optional. Duplicate suppression across a reconnect therefore cannot be based on
a native event receipt. [H8]

### 3. Snapshot consistency

`session.snapshot` contains one live view with:

- Herdr version and protocol;
- focused workspace, tab, and pane IDs;
- workspace, tab, pane, and layout records; and
- Agent records.

The documented client algorithm makes this a consistent cache relative to the
subscription's observed stream: events accepted after subscription setup are
buffered while the snapshot is fetched, then replayed locally in arrival order.
The algorithm does not make a snapshot a historical event log and does not make
the server expose a transaction ID.

On reconnect, Herdr explicitly says to call `session.snapshot` again. Since a
new lifecycle subscription starts at the new request's acceptance point, the
interval between the old connection's loss and the new subscription's
acceptance is unobservable through the native lifecycle stream. [H1] [H2]

For a status subscription, the server also avoids emitting a false snapshot
transition when its probe is unchanged. It compares the current status and
presentation with the last observed values and only emits a change. This is
useful for live observation, but it is not a durable revision protocol. [H6]

### 4. Native event and status surfaces

The available native surfaces are:

| Surface | What it provides | Limitation relevant to the supervisor |
|---|---|---|
| `session.snapshot` | Current workspaces, tabs, panes, layouts, focus, Agents, `terminal_id`, `agent_session`, status, and revisions | One-time current state; no server incarnation or event cursor |
| `events.subscribe` | Long-lived raw-socket events, including lifecycle events and `pane.agent_status_changed` | Raw socket only; connection-scoped; no replay or public sequence |
| `events.wait` | One-shot raw-socket match for an event such as a pane reaching an exact status; can match current state | Not a durable stream or reconnect cursor |
| `agent list/get/wait` | CLI access to Agent identity and `idle`, `working`, `blocked`, `done`, or `unknown`; `agent.wait` is server-owned and event-driven | No CLI subscription command; waits still belong to the process holding the socket |
| `pane get/list` and `agent get/list` | Current pane/Agent placement, `terminal_id`, native session reference, status, and metadata | Current reads only; identity fields must be joined to status events |
| `pane.report_agent` | Integration/plugin writes semantic lifecycle state | A reporter surface, not a durable observer |
| `pane.report_agent_session` | Integration/plugin writes native Agent session identity for restore | Agent conversation identity is not Herdr resource identity |

The 0.9.0 schema accepts all lifecycle subscription kinds for workspace, tab,
worktree, pane, and layout events. The stream's subscription event envelope is
narrower for specialized subscriptions, with `pane.agent_status_changed` as the
native lifecycle status stream. [H1] [H3] [H8]

Herdr status authority depends on the Agent: installed complete lifecycle
integrations can be authoritative, while other Agents use screen-manifest
detection. The five status values are semantic state, not task-success verdicts.
`blocked` means Herdr recognized an input/approval/question state; `unknown`
does not mean completion. [H3]

The current CLI has no `events.subscribe` or `events.wait` command. `herdr api`
exposes only `snapshot` and `schema`; a subscriber must speak newline-delimited
JSON over the local Unix socket (or the platform equivalent). [H1] [local command
transcript above]

### 5. Resource identity continuity

There are three different identity questions, and they must not be conflated.

#### Same-server move

Within one running Herdr server, moving a pane across workspaces can change its
public workspace-qualified `pane_id` while retaining the running terminal and
its `terminal_id`. The 0.9.0 API documents this, and the repository's real
resource-tree test moves a created pane to a new workspace and verifies that the
terminal identity and creator attribution remain continuous. [H1] [L3]

The resource-tree foundation therefore reconciles pane creator edges by
`terminal_id` within a proven server scope, not by pane ID, label, timing,
adjacency, placement, or current occupant. Agent parentage uses the complete
native `agent_session` identity, not a pane or presentation name. [L1] [L2]

#### Cold Herdr/server restart

The repository's disposable real-Herdr test stopped a 0.9.0 server and started
it again with the saved session state. It observed:

- the same logical workspace IDs before and after restore;
- a different Herdr socket filesystem identity;
- a different `terminal_id` for the restored pane; and
- no `boot_id`, `server_id`, or `incarnation_id` in either `session.snapshot`.

The resource-tree query consequently leaves the restored pane's old creator
unknown rather than attaching old provenance. The test is
`test_resource_tree_018_cold_restore_exposes_no_proven_server_continuity`.
[L3]

This establishes the safe contract: cold restore may recover logical layout and
may reuse native-looking resource IDs, but the public 0.9.0 API does not prove
that a restored resource is the same resource incarnation. A server-scoped
registry must not carry old edges into the new socket scope. [L1] [L2]

#### Native Agent session restore

Herdr can resume supported Agent conversations from official integration-reported
session references after server restart. If the reference is missing, invalid,
duplicated, stale, or unsupported, Herdr restores a normal shell instead. This
continuity is for the Agent conversation and does not prove continuity of the
Herdr pane terminal or the resource creator edge. [H2] [H3]

Live handoff is a separate case: it can preserve running PTYs, processes, Agent
identity, and durable metadata, but in-flight API requests, waits, subscription
streams, and pane-to-pane messages may be interrupted. A supervisor must still
reconnect and reconcile after handoff. [H2]

### 6. What PR #283 does and does not deliver

PR #283 is the completed resource-tree foundation. Its summary says that
resources, creator and parent provenance, reconciliation, JSON/CLI projections,
and Claude/OpenCode/Pi context delivery are complete, while the durable
supervisor remains in #214 for later work. [S4]

The implemented foundation:

- reads a fresh native snapshot for placement;
- persists creator intent, finalized creator edges, unresolved operations, and
  managed Agent parentage in SQLite;
- scopes those records to the local Herdr socket filesystem identity;
- preserves explicit uncertainty after a process crash or post-create failure;
- reconciles same-server pane moves by terminal identity; and
- supplies bounded Agent resource context without reading pane contents or
  inferring task success.

The foundation does not persist lifecycle events, host a subscriber, recover a
missed transition, or turn Agent status into task state. Its cold-restore rule is
explicitly "unknown provenance" when continuity cannot be proven. [L1] [L2]

The current ordinary detached child watcher is likewise not the durable
supervisor. It is an external per-child process that polls `herdr pane get`,
validates generation, terminal, and native session identity, then uses local
delivery receipts and `herdr agent prompt` to wake the parent. Its run directory
and watcher process are ephemeral. It does not survive its own crash or machine
restart and does not consume `events.subscribe`. [S3] [L4]

## Implementation Constraints Handed To #285

These are constraints, not implementation changes:

1. **Hosting:** the observer must outlive the parent Agent turn and the ordinary
   per-child watcher. A subscription held by a parent turn cannot be durable.
2. **Startup:** subscribe and receive acknowledgement before snapshot; keep the
   subscription stream buffered while taking the snapshot; install the snapshot;
   apply buffered events in order.
3. **Reconnect:** after observer or server restart, establish a new subscription
   before taking a new snapshot. Treat the absence interval as a known
   observation gap, not as a replayable queue.
4. **Identity:** use the resource-tree server scope, native `terminal_id` for
   same-server pane continuity, and complete native `agent_session` identity for
   Agent parentage. Do not key durable interest solely by `pane_id`, alias,
   label, occupancy, or layout coordinates.
5. **Event joining:** join a `pane.agent_status_changed` event with a fresh
   `pane.get`/`agent.get`/snapshot before acting when terminal or native Agent
   identity matters. The event itself does not carry those identities or a
   public sequence.
6. **Deduplication:** native events cannot provide an exactly-once receipt across
   reconnect. Keep local generation- and delivery-receipt state separate from
   the resource-tree provenance registry and preserve the existing
   timeout-then-settlement semantics.
7. **Loss policy:** define what a child status transition during observer
   downtime means. The native API cannot distinguish a missed `working -> blocked`
   transition from a child that is currently `blocked` after the fact.
8. **No task-state expansion:** do not make the resource tree a second Herdr
   layout database, task manager, result acknowledgement channel, or completion
   inference engine.

## Remaining Uncertainties

- Who starts and restarts the observer, and what durable process owns its socket
  and local state, remains open in #214.
- Registration and deregistration of generation-scoped interests is not defined,
  including stale interests after a parent or child disappears.
- The behavior when the identity-matched parent is gone or itself blocked is not
  defined.
- One machine-wide observer versus one observer per parent is not chosen.
- There is no native public event cursor, server incarnation ID, or resume point
  in Herdr 0.9.0. A future Herdr API could add one; this research does not assume
  it exists.
- Native Agent session restore is integration-dependent and does not establish
  terminal/resource continuity. The repository's cold-restore probe deliberately
  refuses to infer that continuity.
- The exact policy for transitions missed during a subscriber outage must be
  agreed before implementation. No design can claim lossless recovery using only
  the 0.9.0 surfaces measured here.

## Primary Sources

- [S1: issue #288](https://github.com/Seigiard/my-mac-setup/issues/288) - research question and required facts.
- [S2: map #285](https://github.com/Seigiard/my-mac-setup/issues/285) - durable-supervisor destination and out-of-scope foundation.
- [S3: issue #214](https://github.com/Seigiard/my-mac-setup/issues/214) - accepted, deferred supervisor contract and current watcher boundary.
- [S4: PR #283](https://github.com/Seigiard/my-mac-setup/pull/283) - completed resource-tree foundation.
- [H1: Herdr 0.9.0 Socket API](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/socket-api.mdx) - acknowledgement ordering, snapshot bootstrap, raw methods, event subscriptions, socket transport, and status reporting.
- [H2: Herdr 0.9.0 Session State](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/session-state.mdx) - cold restart, native Agent restore, and live handoff limits.
- [H3: Herdr 0.9.0 Agents](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/website/src/content/docs/agents.mdx) - status authority, status meanings, and native session references.
- [H4: Herdr 0.9.0 Changelog](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/docs/next/CHANGELOG.md) - release entry for live-only lifecycle subscriptions and issue #1270.
- [H5: Herdr 0.9.0 API server source](https://github.com/herdrdev/herdr/blob/v0.9.0/src/api/server.rs) - subscription acknowledgement and connection loop.
- [H6: Herdr 0.9.0 subscription source and tests](https://github.com/herdrdev/herdr/blob/v0.9.0/src/api/subscriptions.rs) - setup probing, current-state status matches, setup-window behavior, and no-history test.
- [H7: Herdr 0.9.0 event hub source](https://github.com/herdrdev/herdr/blob/v0.9.0/src/api/event_hub.rs) - internal bounded sequence buffer, not a public replay API.
- [H8: Herdr 0.9.0 event schema](https://github.com/herdrdev/herdr/blob/v0.9.0/src/api/schema/events.rs) - request filters and wire event fields.
- [H9: Herdr 0.9.0 persisted session snapshot source](https://github.com/herdrdev/herdr/blob/v0.9.0/src/persist/snapshot.rs) - what Herdr saves and restores.
- [H10: upstream issue #1270](https://github.com/herdrdev/herdr/issues/1270) - original replay behavior, explicit cursor expectation, and v0.9.0 release confirmation.
- [L1: local resource-tree contract](../herdr-resource-tree.md) - server scope, identity rules, uncertainty, and recovery limits.
- [L2: local ADR-0017](../decisions/0017-intercept-herdr-resource-creation-with-a-path-wrapper.md) - why live placement remains Herdr-authoritative and provenance is separate.
- [L3: local resource-tree tests](../../tests/bashunit/herdr_resource_tree_test.sh) - same-server move identity, cold-restore probe, scope changes, and occupancy controls.
- [L4: local child watcher and runtime](../../home/dot_local/lib/herdr-child-watcher.sh) and [runtime](../../home/dot_local/lib/herdr-child-runtime.sh) - ephemeral polling, generation checks, and local delivery state.
