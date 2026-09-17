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

Show only resources created by the invoking Agent session, while retaining the
minimum structural containers needed to locate them:

```sh
herdr-resource-tree --branch
herdr-resource-tree --branch --json
```

Both forms contain the same resources in native workspace and tab order. Every
resource carries its native `id`, existing `label` (or `null`), and creator when
one was recorded. A pane additionally carries its native `terminal_id` and an
optional current agent observation. Agent presentation names, terminal IDs, and
conversation-session identities are separate fields; none is used to infer
creator or parent provenance. A containing workspace or tab does not confer
ownership of unrelated sibling panes: a branch includes only the panes that the
operation returned, even when their container was also created by that
operation. Managed parentage and indirect descendants are added separately.

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
after process or registry restart. Query-time pane reconciliation requires both
the returned pane ID and terminal ID; it never matches by labels, names, timing,
placement, or current occupant. Missing optional native labels do not affect
recording.

The registry stores caller identity, operation state, and returned coordinates;
it does not store command arguments or `--env` values. Replacing the Herdr
server socket changes the scope, so records from an earlier server lifetime do
not attach even if native pane and terminal IDs are later reused.

If identity or intent recording fails, the wrapper returns nonzero before
creating resources. If Herdr creates resources but response parsing or
provenance finalization fails, native success JSON remains on stdout, all
created resources remain open, and stderr reports the operation ID, all known
coordinates, and that automatic creation retry is unsafe. A crash with no
recoverable response leaves the durable intent uncertain and live resources
unattributed. The injected operation ID is not snapshot-discoverable on Herdr
0.9.0, so the wrapper neither guesses a match nor retries creation.

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
  any newly created container. Moving a pane does not create its terminal.

Those resources remain visible with unknown creator until their own contracts
are implemented. `plugin action` is not such a boundary: it acknowledges an
asynchronous action and does not return resources the action later creates.
Custom command invocation likewise returns only an acknowledgement. Popup
plugin panes return no durable pane identity. Creation behind these paths,
behind an absolute native binary, or through the TUI is explicitly
unknown-provenance behavior rather than claimed wrapper coverage.

## JSON Contract

The top-level object has this shape:

```json
{
  "schema_version": 1,
  "scope": {
    "kind": "local-herdr-server",
    "version": "0.9.0",
    "protocol": 22
  },
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
                "parent_session": null
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
`protocol`. `agent` is `null` for a pane with no current agent observation.
`agent.session` is `null` when Herdr observes an agent but does not supply its
optional conversation identity. A recorded resource `creator_session` has the
same four-field native identity shape. Unrecorded resource creators and every
`parent_session` remain `null`; this CLI never guesses them from labels,
containment, terminal identity, or occupancy.

Snapshot command failures, invalid JSON, missing arrays, duplicate identities,
and inconsistent containment return nonzero with a diagnostic on stderr. They
never produce a complete-looking empty tree.
