---
title: Intercept Herdr resource creation with a PATH wrapper
status: accepted
date: 2026-09-18
supersedes: []
---

# ADR-0017: Intercept Herdr resource creation with a PATH wrapper

## Context

Herdr reports which panes, tabs, and workspaces exist and which Agent occupies
each one. It does not report who asked for them. An agent that splits a pane and
an agent that merely shares a workspace are indistinguishable in a snapshot, so
no agent can be given a bounded view of the resources it is responsible for.

Attribution needs a synchronous boundary at the moment of creation, because that
is the only moment at which the requesting session and the created resource are
both known. A snapshot taken afterwards cannot recover the link: by then the
pane is just a pane, and a replacement occupant would inherit whatever the
attribution claimed.

The constraint that shapes the options is that creation is not ours to
re-implement. Agents, the Command Palette, `herdr-child`, and the user's own
shell all call `herdr` directly, and any boundary that only some of them pass
through produces a registry that is silently incomplete rather than empty.

[`docs/herdr-resource-tree.md`](../herdr-resource-tree.md) holds the resulting
contract — what the registry stores, what stays Herdr's to answer, and how each
failure mode is kept distinguishable from an empty branch.

## Considered options

- **Wait for a native Herdr provenance API.** The correct long-term home, and
  it removes the wrapper entirely. Herdr exposes no creator field today and none
  is announced, so this defers the feature indefinitely.
- **A dedicated `herdr-create` helper that agents are instructed to use.**
  No interception, no PATH ordering, no wrapper cost on unrelated calls. But
  attribution then depends on every caller choosing the helper; a direct `herdr
  pane split` — from the user, from a skill, from a tool that predates the
  helper — creates an unattributed resource, and nothing distinguishes that from
  a resource created by nobody.
- **A Herdr plugin.** Runs inside the process that performs the creation, so it
  cannot be bypassed. Herdr's plugin API observes and dispatches commands but
  does not expose the requesting shell's session identity, which is the value
  being recorded. It also makes the feature depend on a plugin lifecycle the
  repository does not own.
- **A PATH wrapper that shadows the `herdr` binary.** Every caller passes
  through it without knowing it exists, and the wrapper sees both the invoking
  pane and the native response.
- **No attribution.** Agents keep the full snapshot. Rejected because an
  unbounded resource list is the problem being solved.

## Decision

Install `~/.local/bin/herdr` as a managed wrapper and order `PATH` so it
precedes the Homebrew binary. It intercepts `pane split`, `tab create`, and
`workspace create`; every other invocation reaches the native binary through
`os.execv` with the wrapper's own dispatch cost and nothing else.

The wrapper records creation intent before invoking Herdr, invokes Herdr exactly
once, and finalizes the record against the native response. A bookkeeping
failure after a successful create never retries and never cleans up: it reports
the surviving coordinates and marks automatic retry as unsafe, because the
resource exists and only our record of it is missing.

The registry stores only what Herdr does not provide — creation intent, creator
identity, Agent parentage, and unresolved operations — keyed on the socket's
filesystem identity so a restarted server does not inherit a previous server's
edges. Live placement is read from Herdr on every query.

Consumers that do not need interception resolve the native binary directly
rather than through the wrapper. `herdr-child` is the exception in the other
direction: it resolves the wrapper by path next to itself, because a creation
that reaches the native binary produces a child with no recorded creator.

## Consequences

Attribution is unbypassable for any caller whose PATH is the managed one, which
is the property the alternatives could not provide. The cost is a permanent
managed shadow of a third-party binary: a Herdr upgrade that changes the
creation response shape breaks parsing, and the wrapper must keep passing
unrecognized subcommands through untouched.

PATH ordering becomes load-bearing, and any process that keeps a pre-deployment
environment keeps the old resolution until its shell restarts. Callers that must
not silently lose attribution therefore resolve the wrapper by path rather than
trusting PATH.

The wrapper is a migration, not an architecture. If Herdr gains a native creator
field, the registry's creator table and the interception both become removable
without touching the projection the clients consume.
