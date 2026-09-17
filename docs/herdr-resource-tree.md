# Herdr Resource Tree

`herdr-resource-tree` reads one `herdr api snapshot` from the current local
server and projects every open workspace, tab, and pane as a tree. A managed
`herdr` PATH wrapper records which Agent session created a pane through ordinary
`herdr pane split` use. The service persists provenance, not a second copy of
placement, and does not read pane contents or manage resource lifecycle.

Use the human-readable view interactively:

```sh
herdr-resource-tree
```

Use the versioned JSON projection from downstream tools:

```sh
herdr-resource-tree --json
```

Show only panes created by the invoking Agent session, while retaining their
current structural workspace and tab containers:

```sh
herdr-resource-tree --branch
herdr-resource-tree --branch --json
```

Both forms contain the same resources in native workspace and tab order. Every
resource carries its native `id`, existing `label` (or `null`), and creator when
one was recorded. A pane additionally carries its native `terminal_id` and an
optional current agent observation. Agent presentation names, terminal IDs, and
conversation-session identities are separate fields; none is used to infer
creator or parent provenance. A branch includes only direct pane creations in
this slice; managed parentage and indirect descendants are added separately.

## Recording Contract

`~/.local/bin/herdr` discovers the original executable from `HERDR_BIN_PATH` or
the next distinct executable on `PATH`. All commands except the exact local
`pane split` form are executed directly by the original binary, preserving
native arguments, streams, signals, and exit behavior. Global-option, remote,
absolute-binary, TUI, tab, workspace, worktree, and plugin creation paths bypass
pane attribution in this slice and remain visible with unknown provenance.

Before an Agent-managed split, the wrapper reads the invoking pane and requires
its full native `agent_session`. The invoking session remains the creator even
when the command splits another Agent's pane. A shell pane without an observed
Agent remains usable and creates a pane with unknown provenance.

For a managed split, the wrapper commits a unique operation intent to
`${XDG_STATE_HOME:-~/.local/state}/herdr-resource-tree/registry.sqlite3`, scoped
to the local Herdr socket path and filesystem identity, before invoking native
creation exactly once. It then finalizes the creator edge from native success
JSON. Separate database connections read the same edge after process or
registry restart. Query-time reconciliation requires both the returned pane ID
and terminal ID; it never matches by labels, names, timing, placement, or
current occupant.

The registry stores caller identity, operation state, and returned coordinates;
it does not store command arguments or `--env` values. Replacing the Herdr
server socket changes the scope, so records from an earlier server lifetime do
not attach even if native pane and terminal IDs are later reused.

If identity or intent recording fails, the wrapper returns nonzero before
opening a pane. If Herdr creates the pane but response parsing or provenance
finalization fails, native success JSON remains on stdout, the pane remains
open, and stderr reports the operation ID, all known coordinates, and that
automatic creation retry is unsafe. A crash with no recoverable response leaves
the durable intent uncertain and the live pane unattributed. The injected
operation ID is not snapshot-discoverable on Herdr 0.9.0, so the wrapper neither
guesses a match nor retries creation.

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
optional conversation identity. A recorded pane `creator_session` has the same
four-field native identity shape. Unrecorded resource creators and every
`parent_session` remain `null`; this CLI never guesses them from labels,
containment, terminal identity, or occupancy.

Snapshot command failures, invalid JSON, missing arrays, duplicate identities,
and inconsistent containment return nonzero with a diagnostic on stderr. They
never produce a complete-looking empty tree.
