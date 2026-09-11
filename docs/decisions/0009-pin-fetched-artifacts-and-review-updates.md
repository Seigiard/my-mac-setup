---
title: Pin fetched artifacts and review updates
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0009: Pin fetched artifacts and review updates

## Context

Chezmoi fetches code and binaries that execute in the user's shell and agent
environment. Mutable upstream references would let the same repository revision
produce different machines. Some artifacts must also bootstrap in minimal CI
before mise is available. The current policy is declared in
`home/.chezmoiexternal.toml` and its pin updates are visible as isolated commits.

## Considered options

- Follow mutable branches or latest-release URLs automatically.
- Delegate every binary installation to the normal tool manager.
- Pin immutable revisions and checksums, then update them through explicit
  reviewed repository changes.

## Decision

Repository-managed externals use immutable commit or release URLs. Binary
artifacts carry per-platform SHA-256 checksums. Update automation may prepare a
pin change, but the managed source changes only through ordinary repository
review. Bootstrap requirements may justify a chezmoi external instead of the
normal tool manager.

## Consequences

One repository revision remains reproducible and upstream changes cannot execute
without a visible pin update. Updates require deliberate maintenance, and parent
archive ownership must remain compatible with separately managed child paths.
