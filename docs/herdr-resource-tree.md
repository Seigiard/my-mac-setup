# Herdr Resource Tree

`herdr-resource-tree` reads one `herdr api snapshot` from the current local
server and projects every open workspace, tab, and pane as a tree. A managed
`herdr` PATH wrapper records which Agent session created resources through
ordinary `herdr pane split`, `herdr tab create`, and `herdr workspace create`
use. The service persists provenance, not a second copy of placement, and does
not read pane contents or manage resource lifecycle.

Use the human-readable view interactively:

```sh
herdr-resource-tree
```

Use the versioned JSON projection from downstream tools:

```sh
herdr-resource-tree --json
```

Show resources created by the invoking Agent session or any of its managed
descendants, while retaining the minimum structural containers needed to locate
them:

```sh
herdr-resource-tree --branch
herdr-resource-tree --branch --json
```

Both forms contain the same resources in native workspace and tab order. Every
query takes a fresh native snapshot; persisted records supply provenance, never
placement. A branch also identifies its selected session, direct parent, and
transitive managed descendants that remain anchored by a live Agent session or
live created resource. Every resource carries its native `id`, existing `label`
(or `null`), and creator when one was recorded. A pane additionally carries its
native `terminal_id` and an optional current agent observation. Agent
presentation names, terminal IDs, conversation-session identities, resource
creators, current occupants, live containment, and managed Agent parents are
separate fields; none is inferred from another.

A containing workspace or tab does not confer ownership of unrelated sibling
panes. A branch includes only resources created by the selected session or its
recorded descendants. An unrelated Agent occupying an included pane is shown as
that pane's occupant, but its own resources and descendants are not pulled into
the branch. A closed ancestor remains visible only while it connects a live
descendant session or a session with a live created resource. An ended leaf is
omitted after its last created resource closes, but its exact stored session
edge remains available if that same native conversation resumes. Conversely, a
child's pane can be absent from its own branch when the parent created that
pane; the child's branch begins with resources the child or its descendants
created.

## Recording Contract

`~/.local/bin/herdr` discovers the original executable from `HERDR_BIN_PATH` or
the next distinct executable on `PATH`. The exact local `pane split`, `tab
create`, and `workspace create` forms are tracked; their help forms and all
other commands are executed directly by the original binary. Global-option,
remote, absolute-binary, and TUI creation paths bypass attribution and remain
visible with unknown provenance.

Before an Agent-managed creation, the wrapper reads the invoking pane and
requires its full native `agent_session`. The invoking session remains the
creator even when the command targets another Agent's container. A shell pane
without an observed Agent remains usable and creates resources with unknown
provenance.

For a managed creation, the wrapper commits a unique operation intent to
`${XDG_STATE_HOME:-~/.local/state}/herdr-resource-tree/registry.sqlite3`, scoped
to the local Herdr socket path and filesystem identity, before invoking native
creation exactly once. It then finalizes creator edges from native success JSON:
one pane for a split, one tab and its root pane for tab creation, or one
workspace, its initial tab, and its root pane for workspace creation. The
operation row distinguishes returned containers from the existing containers
that merely locate a split. Separate database connections read the same edges
after process or registry restart. Query-time pane reconciliation uses the
returned terminal identity within the proven server scope, so a native move may
change the pane ID and placement without changing creator provenance. Workspace
and tab provenance uses their returned native IDs. Reconciliation never matches
by labels, names, timing, adjacency, placement, or current occupant. Missing
optional native labels do not affect recording.

The registry stores caller identity, operation state, and returned coordinates;
it does not store command arguments or `--env` values. The query verifies the
socket filesystem identity before and after snapshot retrieval and refuses to
combine a snapshot with a different server scope. Replacing the Herdr server
socket changes the scope, so records from an earlier server lifetime do not
attach even if native resource IDs are restored or reused.

## Managed Agent Parentage

`herdr-child start` records an Agent parent edge only after Herdr has accepted
the child launch and the launcher has revalidated its alias, pane, terminal, and
conversation session. It calls:

```sh
herdr-resource-tree record-child --pane <pane-id> --terminal <terminal-id> \
  --child-name <verified-alias> --child-session-json <verified-native-session>
```

This write command independently reads the current parent, takes a fresh Herdr
snapshot, verifies the live child at the supplied pane and terminal, and
requires the managed wrapper's creator edge for that exact pane to identify the
same parent session. The child's fresh alias and full native session must also
equal the launcher's post-start verification, so a replacement occupant cannot
acquire the edge. It then stores the parent and child session identities and
their launch-time presentation names in the same server-scoped registry. The
operation is idempotent for the same edge and rejects conflicting parents,
self-parentage, and cycles.

Pane creation alone never records Agent parentage. Parentage is keyed by the
complete native Agent session identity, not its pane or presentation name. The
same native conversation therefore keeps its relationship after a move, rename,
compaction, or resume. A later manual or new conversation in a pane created by
another Agent therefore remains an unrelated occupant.
Raw `herdr agent start` calls likewise have unknown parentage. Both pane and tab
launch modes use the same recorder after their existing launch verification. An
attached launch from a shell without an observable parent Agent session remains
usable and records no parent rather than inventing one.

If parentage recording fails after Agent start, `herdr-child` returns the
recorder's nonzero status, reports the child coordinates, and preserves the live
child without submitting the initial task. It explicitly warns that automatic
launch retry is unsafe. If the managed wrapper returns nonzero after reporting a
created pane or tab, the launcher preserves and reprints that native result and
does not start an Agent, retry creation, or clean up the surviving resource.

If identity or intent recording fails, the wrapper returns nonzero before
creating resources. If Herdr creates resources but response parsing or
provenance finalization fails, native success JSON remains on stdout, all
created resources remain open, and stderr reports the operation ID, all known
coordinates, and that automatic creation retry is unsafe. The durable operation
also appears under `unresolved_operations` in subsequent human, JSON, branch,
and context queries. A crash with no recoverable response leaves the durable
intent uncertain, with no known coordinates, and live resources unattributed.
The injected operation ID is not snapshot-discoverable on Herdr 0.9.0, so the
wrapper neither guesses a match nor retries creation.

## Other Creation Surfaces

The following Herdr 0.9.0 commands have synchronous response identities that a
future slice can intercept reliably, but this wrapper does not yet attribute
them:

- `worktree create` returns the created workspace, tab, root pane, and worktree.
- `worktree open` returns the same records plus `already_open`; an already-open
  result must not be claimed as a new creation.
- `plugin pane open` returns a pane identity for overlay, split, tab, and zoomed
  placements.
- `pane move --new-tab` and `pane move --new-workspace` return the moved pane and
  any newly created container. A previously attributed pane keeps its creator
  because fresh snapshots reconcile its stable live terminal identity; containers
  created by the move remain unattributed.

Those newly created resources remain visible with unknown creator until their
own contracts are implemented. `plugin action` is not such a boundary: it acknowledges an
asynchronous action and does not return resources the action later creates.
Custom command invocation likewise returns only an acknowledgement. Popup
plugin panes return no durable pane identity. Creation behind these paths,
behind an absolute native binary, or through the TUI is explicitly
unknown-provenance behavior rather than claimed wrapper coverage.

## JSON Contract

The top-level object has this shape:

```json
{
  "schema_version": 3,
  "scope": {
    "kind": "local-herdr-server",
    "version": "0.9.0",
    "protocol": 22
  },
  "unresolved_operations": [],
  "workspaces": [
    {
      "id": "w1",
      "number": 1,
      "label": "project",
      "creator_session": null,
      "tabs": [
        {
          "id": "w1:t1",
          "number": 1,
          "label": "agents",
          "creator_session": null,
          "panes": [
            {
              "id": "w1:p1",
              "label": "oc:red-fox",
              "terminal_id": "term_123",
              "creator_session": null,
              "agent": {
                "client": "opencode",
                "presentation_name": "red-fox",
                "session": {
                  "agent": "opencode",
                  "kind": "id",
                  "source": "herdr:opencode",
                  "value": "ses_123"
                },
                "parent_session": null,
                "parent_name": null
              }
            }
          ]
        }
      ]
    }
  ]
}
```

`schema_version` versions this projection, independently of Herdr's native
`protocol`. Version 2 added durable Agent parent links and branch metadata.
Version 3 adds `unresolved_operations`; each entry contains the operation ID,
creation kind, caller session, reason, any known returned coordinates, and
`"retry_safe": false`.
`agent` is `null` for a pane with no current agent observation. `agent.session`
is `null` when Herdr observes an agent but does not supply its optional
conversation identity. A recorded resource `creator_session` and Agent
`parent_session` have the same four-field native identity shape. Unknown creator
or parent fields remain `null`; this CLI never guesses them from labels,
containment, aliases, timing, adjacency, or occupancy.

With `--branch --json`, the top-level object also contains:

```json
{
  "branch": {
    "session": { "agent": "opencode", "kind": "id", "source": "herdr:opencode", "value": "ses_b" },
    "presentation_name": "agent-b",
    "parent": {
      "presentation_name": "agent-a",
      "session": { "agent": "claude", "kind": "id", "source": "herdr:claude", "value": "ses_a" }
    },
    "descendants": [
      {
        "presentation_name": "agent-c",
        "session": { "agent": "pi", "kind": "id", "source": "herdr:pi", "value": "ses_c" },
        "parent_session": { "agent": "opencode", "kind": "id", "source": "herdr:opencode", "value": "ses_b" }
      }
    ]
  }
}
```

`descendants` is breadth-first and includes indirect descendants still anchored
by a live Agent session or live created resource. `parent` is
`null` for a root or unknown-parent session. Presentation names are labels for
display; the complete native session object is the relationship identity.

## Shared Agent Context

Client adapters consume one bounded text projection rather than rebuilding the
tree or reading the registry:

```sh
herdr-resource-tree --context
```

The command resolves the invoking native Agent session exactly as `--branch`
does. It emits the known parent name, descendant identities, and the
filtered resource branch with existing labels, native coordinates, terminal
identities, creators, occupants, and parent links. It never includes pane
contents, native activity labels, task status, or inferred verdicts.

The default projection is at most 4096 characters. Deployments may select a
bound from 256 through 16384 with `HERDR_RESOURCE_CONTEXT_MAX_CHARS`. When the
projection does not fit, it ends with
`herdr-resource-tree --branch` as the route to the unabridged human query. An
Agent with no created resources gets no empty `Resources` section. A known
parent line remains available even when that Agent's resource branch is empty;
a root with no resources, descendants, or unresolved creations emits no context.

Client adapters that receive a native conversation identity should guard against
a pane-occupant race:

```sh
herdr-resource-tree --context \
  --caller-agent claude \
  --caller-session-id "$CLAUDE_SESSION_ID"
```

Both guard options are required together and are valid only with `--context`.
The query fails when the current Herdr Agent session's client or native id no
longer matches, so a fresh conversation cannot receive the previous occupant's
resource branch.

Claude's adapter supplies the projection as `additionalContext` on
`SessionStart`, `UserPromptSubmit`, and `PostToolBatch`. It emits nothing when a
mid-session projection is unchanged. When the projection changes, the new
reminder declares itself authoritative and invalidates the earlier generated
context. Claude's transcript is append-only, so the earlier reminder remains in
history; the supported hook API cannot physically remove it.

Snapshot command failures, invalid JSON, missing arrays, duplicate identities,
and inconsistent containment return nonzero with a diagnostic on stderr. They
never produce a complete-looking empty tree.

## Recovery Guarantees

The following behavior is demonstrated against Herdr 0.9.0 and the public
CLI/JSON boundary:

- Provenance survives resource-tree process and registry reopen because finalized
  operations and parent edges are committed to SQLite before success returns.
- Every successful query uses fresh native placement. Same-server pane moves may
  change the canonical pane ID while retaining terminal identity and creator.
- Closed resources disappear without being closed by this service. Parent edges
  are projected only while needed to connect live sessions or live created
  resources.
- A concurrent query can observe an operation before finalization as unresolved or
  unattributed, but the read-only reconciliation cannot erase the later successful
  finalization.
- Failed, malformed, timed-out, or cross-scope snapshots return nonzero and do not
  prune durable provenance.

Cold Herdr or computer restoration is deliberately not promised. A native 0.9.0
cold-restart probe restores logical workspace slots but allocates fresh terminal
identities, changes the socket filesystem identity, and exposes no public server
incarnation token in `session_snapshot`. Those observations cannot prove process
or creator continuity, so restored resources remain visible with unknown
provenance. A future Herdr identity that proves continuity can extend this rule;
labels, restored coordinates, presentation names, timing, and adjacency cannot.
