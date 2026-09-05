---
title: "Herdr reap invalidation tests fail in Ubuntu"
short_description: "The reap invalidation readiness barrier is never observed in tests 264 and 270 on both macOS and Ubuntu, blocking the full deployment gate after chezmoi apply succeeds."
type: "bug"
category: "herdr"
tags: ["regression","testing"]
date: "2026-09-04"
status: "done"
priority: "high"
closed: "2026-09-05"
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

## Resolution

Fixed by 68d8894 (fix(tests): follow allocated herdr child aliases, #167). Root cause was the test harness, not the reap lifecycle: tests 264/270 invoked reap --to orange-panda, a hardcoded alias that no longer matched the allocated child, so reap bailed out before begin_reap_invalidation and reap-invalidated.ready was never written. The call sites now read --to "$(child_started_name)" at tests/bashunit/scripts_test.sh:7556 and :7800. Verified on macOS with the record's own repro: tests/lib/bashunit -f reap_invalidation tests/bashunit/scripts_test.sh gives 2 passed, 17 assertions. Not re-run under make test-ubuntu; the fix lives in shared harness code with no platform-dependent behaviour. The stated blocker 2026-08-30-006 is also closed (done, 2026-09-04).
