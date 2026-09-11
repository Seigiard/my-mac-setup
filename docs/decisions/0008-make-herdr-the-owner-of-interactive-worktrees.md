---
title: Make Herdr the owner of interactive worktrees
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0008: Make Herdr the owner of interactive worktrees

## Context

Interactive worktree lifecycle crosses Git, Herdr, shell tooling, plugins, and
agent identity. Authorizing branch mutation from a `worktree/*` name would let a
convention grant authority over a user-owned branch. The ownership model is
specified in `docs/herdr-worktrees.md`; commit `4adc681` moved lifecycle from
Worktrunk to native Herdr worktrees.

## Considered options

- Keep worktree lifecycle in Worktrunk alongside Herdr sessions.
- Let a generated branch-name prefix authorize automated mutation.
- Give lifecycle to Herdr and require a lifecycle-owned marker before changing
  generated Git identity.

## Decision

Herdr solely owns creation, opening, closing, and removal of interactive
worktrees. The repository plugin performs post-create setup and writes a
`herdr-generated-worktree` marker in the per-worktree Git administrative
directory. Automated branch renaming is allowed only when that marker proves
Herdr provenance; branch text never grants authority.

## Consequences

Lifecycle and repository setup have distinct owners, and a generated checkout
can be named without risking unrelated branches. Failed or ambiguous provenance
must leave Git identity unchanged, even when that produces a less convenient
workspace name.
