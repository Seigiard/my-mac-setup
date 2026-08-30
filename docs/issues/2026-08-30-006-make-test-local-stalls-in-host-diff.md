---
title: "make test-local stalls in host diff"
short_description: "chezmoi diff --source=./home remained live for more than eight minutes while rendering host-specific 1Password-backed Claude configuration; the disposable make test-ubuntu gate still passed."
type: "bug"
category: "testing-ci"
tags: ["chezmoi","host-verification"]
date: "2026-08-30"
status: "open"
priority: "medium"
---

## Why this exists

`make test-local` invokes `chezmoi diff --source=./home` against the real host
configuration. During the herdr-child module refactor, the command remained
live for 8 minutes 45 seconds while rendering host-specific, 1Password-backed
Claude configuration and was interrupted with Ctrl-C. It produced no
completion verdict, so it cannot be cited as verification evidence.

The disposable `make test-ubuntu` gate completed successfully for the same
managed-file changes. The unresolved problem is therefore specific to the
host dry-run path, not evidence that the checkout cannot be applied.

## Scope

- Reproduce the stall with bounded timing and identify the last template or
  external lookup reached by `chezmoi diff`.
- Determine whether the delay comes from 1Password access, template rendering,
  or chezmoi's host-state comparison.
- Add diagnostics or a bounded failure mode so `make test-local` cannot remain
  silently live without a useful verdict.
- Preserve the rule that host verification must not apply managed changes.

## Open decisions

- Whether secret-backed templates should be excluded from this dry-run or
  retained with an explicit timeout and diagnostic.
