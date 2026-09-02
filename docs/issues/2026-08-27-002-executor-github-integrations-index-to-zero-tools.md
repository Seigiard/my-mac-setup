---
title: "Executor GitHub integrations index to zero tools"
short_description: "In the local Executor daemon the github_rest (OpenAPI) and github_graphql integrations both report toolCount 0 and have no connection, while linear_mcp indexes 65 tools and reports healthy, so GitHub cannot be called through Executor until the index or the spec import is repaired."
type: "bug"
category: "agent-platform"
tags: ["executor","mcp","github"]
date: "2026-08-27"
status: "wontfix"
priority: "medium"
closed: "2026-08-28"
---

## Why this exists

The local Executor daemon (desktop app v1.6.0, scope `~/.executor`) reports:

```
$ executor tools integrations
executor        built-in   35 tools
linear_mcp      mcp        65 tools   connection healthy
github_rest     openapi     0 tools   no connection
github_graphql  graphql     0 tools   no connection
```

`linear_mcp` proves the daemon and its indexer work, so the zero counts are
specific to the two GitHub integrations rather than a general fault. Neither
has a connection, and an integration with no indexed tools cannot be called
regardless of auth, so GitHub is unreachable through Executor while Linear is
not.

Root cause is not yet established. Candidates: the OpenAPI import never
finished indexing, the spec fetch failed silently, or the GraphQL endpoint
needs credentials before it will introspect.

## Scope

Refresh `github_rest` and confirm a non-zero tool count. If the refresh does
not fix it, capture the daemon log for the import and identify whether the
failure is fetch, parse, or index. Then create a connection and prove one
read-only `GET` tool returns live data. Decide separately whether
`github_graphql` is worth keeping alongside `github_rest`.

## Open decisions

Whether to keep both GitHub integrations or drop `github_graphql` and rely on
`github_rest` alone.

## Resolution

The github_rest and github_graphql integrations were removed from Executor rather than repaired: the gh CLI already covers GitHub access with existing auth, so proxying it through Executor added a layer without adding capability. Executor now carries chrome_devtools, linear_mcp and posthog, all indexing tools normally, so the zero-tool symptom has no remaining instance to diagnose.
