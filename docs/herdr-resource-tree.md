# Herdr Resource Tree

`herdr-resource-tree` reads one `herdr api snapshot` from the current local
server and projects every open workspace, tab, and pane as a tree. It does not
query remote servers, retain a second copy of placement, read pane contents, or
manage resource lifecycle.

Use the human-readable view interactively:

```sh
herdr-resource-tree
```

Use the versioned JSON projection from downstream tools:

```sh
herdr-resource-tree --json
```

Both forms contain the same resources in native workspace and tab order. Every
resource carries its native `id`, existing `label` (or `null`), and explicit
unknown creator. A pane additionally carries its native `terminal_id` and an
optional current agent observation. Agent presentation names, terminal IDs, and
conversation-session identities are separate fields; none is used to infer
creator or parent provenance.

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
optional conversation identity. `creator_session` and `parent_session` remain
`null` until a later provenance recorder supplies those relationships; this CLI
never guesses them from labels, containment, terminal identity, or occupancy.

Snapshot command failures, invalid JSON, missing arrays, duplicate identities,
and inconsistent containment return nonzero with a diagnostic on stderr. They
never produce a complete-looking empty tree.
