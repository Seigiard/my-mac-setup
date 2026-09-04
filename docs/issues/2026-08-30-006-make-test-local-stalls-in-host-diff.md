---
title: "make test-local requires interactive 1Password authorization"
short_description: "make test-local invokes op read for the Jina credential and can wait indefinitely for interactive 1Password authorization when no person is present, so the verification command is unsafe for unattended agent runs."
type: "bug"
category: "testing-ci"
tags: ["chezmoi","host-verification"]
date: "2026-08-30"
status: "done"
priority: "medium"
closed: "2026-09-04"
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

A bounded current reproduction remained live for 30 seconds. The process tree
ended at `modify_dot_claude.json` calling `op read` for the Jina credential and
waiting for interactive 1Password authorization. With `op` excluded from
`PATH`, the same direct `chezmoi diff` completed in under one second. An agent
or unattended job cannot satisfy the authorization prompt, so an unbounded
wait is an invalid verification contract rather than an ordinary slow lookup.

## Scope

- Detect when interactive 1Password authorization is unavailable and fail fast
  with a diagnostic that names the blocked `op read` invocation.
- Bound the authorization wait even when `op` is present and initially appears
  usable.
- Preserve the rule that host verification must not apply managed changes.
- Preserve a meaningful host diff; globally hiding `op` must not turn missing
  secret rendering into misleading differences.

## Open decisions

- Whether unattended mode should reject secret-backed rendering before diff or
  render it through a deterministic non-secret substitute; silently omitting
  secrets would make the diff verdict misleading.

## Resolution

Resolved by merged PR #165 (cbccaa6): make test-local now runs through the unattended host-partial launcher, prevents interactive 1Password access, and explicitly reports omitted credential-backed targets. Verified on 2026-09-04: make test-local completed successfully without an authorization prompt.
