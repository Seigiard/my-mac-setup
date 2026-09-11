---
title: Scan the full checkout before external peer launches
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0012: Scan the full checkout before external peer launches

## Context

External Claude, OpenCode, and Pi peers can start at the live repository root and
read tracked and untracked files, regardless of the narrower payload named in
their prompt. Repository content then crosses an irreversible third-party
boundary. The former shared scan disappeared with the Smithers runtime; the
resulting gap is tracked in
`docs/issues/2026-09-04-001-pre-external-secret-scan-covers-one-of-five-external-peer-launch-paths.md`.

## Considered options

- Accept unscanned launches or fail open when the scanner is unavailable.
- Make each caller scan only the document or diff it intends to discuss.
- Put one fail-closed full-checkout gate in the shared peer-launch procedure.
- Launch peers from an immutable snapshot instead of the live checkout.

## Decision

Every external peer path, including standalone Claude, OpenCode, or Pi launches
through `ask-in-herdr`, must pass a `gitleaks` full-checkout scan through the
shared peer-launch procedure immediately before any peer tab is created. Run one
scan for a two-peer review pair and one for each standalone launch. The result is
never cached across launches. Output is redacted, scanner exit codes are handled
explicitly, and a missing scanner, finding, or unknown failure blocks launch.
Safe 1Password references such as `op://...` must not be treated as leaked
credentials.

## Consequences

New callers inherit the boundary automatically, but every external review pays
the scan latency and can be blocked by false positives or scanner failure. The
scan is a point-in-time check of a live checkout: concurrent external mutation
after it remains an accepted residual risk. An immutable review snapshot is out
of scope because it would change what the peers inspect. This ADR records the
accepted target and resolves the open decisions in the linked issue; that issue
remains open only for implementation and verification.
