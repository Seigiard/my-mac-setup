# Triage Labels

The repository uses native GitHub labels for two independent roles.

## Category

Each issue has exactly one category label:

| Label | Meaning |
|---|---|
| `bug` | Existing behavior is broken or regressed |
| `enhancement` | New behavior, maintenance, documentation, or improvement work |

## State

Each issue has exactly one canonical state label:

| Label | Meaning |
|---|---|
| `needs-triage` | A maintainer needs to evaluate the issue |
| `needs-info` | Waiting on the reporter for more information |
| `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | Requires human implementation or judgment |
| `wontfix` | Will not be actioned |

Read all current labels before editing an issue. Remove the previous category or state label when changing that role, and preserve unrelated labels. The assignee is the in-progress signal; assigning a user claims the issue for immediate work.
