---
title: "Herdr reap invalidation tests fail in Ubuntu"
short_description: "The reap invalidation readiness barrier is never observed in tests 264 and 270 on both macOS and Ubuntu, blocking the full deployment gate after chezmoi apply succeeds."
type: "bug"
category: "herdr"
tags: ["regression","testing"]
date: "2026-09-04"
status: "open"
priority: "high"
---

## Why this exists

`make test-ubuntu` reaches the post-apply suite after the unattended chezmoi
image build, initialization, apply, and idempotency checks succeed. Tests 264
and 270 in `tests/bashunit/scripts_test.sh` then fail because
`reap-invalidated.ready` is not created within their wait bound.

The same focused command fails on macOS and in the built Ubuntu container:

```sh
tests/lib/bashunit -f reap_invalidation tests/bashunit/scripts_test.sh
```

This blocks the complete local deployment gate required to close unattended
chezmoi issue `2026-08-30-006`.

## Scope

- Determine why `begin_reap_invalidation` does not reach the controlled barrier
  after delivery enters the blocked pane-get state.
- Repair the lifecycle behavior or its test synchronization without weakening
  the causal readiness-file oracle.
- Pass the focused filter on macOS and Ubuntu, then rerun `make test-ubuntu`.

## Open decisions

None.
