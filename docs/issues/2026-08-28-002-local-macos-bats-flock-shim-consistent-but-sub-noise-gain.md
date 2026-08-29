---
title: "Local macOS bats flock shim: consistent but sub-noise gain"
short_description: "A python-fcntl flock shim on run-post-apply.sh's PATH (replacing bats' shlock fallback on Darwin hosts) gave a stable -3..-8s (~3%) host-suite improvement across three interleaved pairs — real but below the 5% keep threshold; the tested diff and full timing data live in the 2026-08-28 test-suite-time optimization log, worth revisiting if host parallelism or suite size grows."
type: "idea"
category: "testing-ci"
tags: ["performance","bats","macos"]
date: "2026-08-28"
status: "done"
priority: "low"
closed: "2026-08-29"
---

## Why this exists

Local Macs ship neither `flock` nor `lockf`, so bats' within-file semaphore
falls back to `shlock`, which polls a contended lock on a one-second sleep.
CI macOS already routes around this with `scripts/ci/macos-bats-flock-bin`
(lockf), and that wrapper measurably helped CI. A local equivalent was
prototyped during the 2026-08-28 test-suite-time optimization run: a
python-fcntl `flock` shim placed on PATH by `tests/run-post-apply.sh` only
on Darwin hosts without a real flock. Across three interleaved A/B pairs on
a clean process floor it improved the host-safe suite by a consistent
-3..-8s (~3%) — real, but below the run's 5% keep threshold, and most of
the historically observed shlock pain turned out to be orphaned-watcher
accumulation (docs/issues/2026-08-28-001), not lock polling.

The tested implementation (shim + 5-case regression test + runner PATH
branch) and full timing data are recorded in the optimization run log
(`.context/compound-engineering/ce-optimize/test-suite-time/` scratch and
`docs/benchmarks/test-suite-optimization.md` once landed).

## Scope

Revisit if the host suite grows, `--jobs` rises, or lock contention
reappears after the watcher leak is fixed: re-run the interleaved pairs;
adopt the shim if the gain clears the noise floor then.

## Open decisions

None.

## Resolution

Obsolete: the post-apply suite no longer runs on bats. Commit 051d3de replaced it with bashunit (tests/run-post-apply.sh invokes tests/lib/bashunit -j) and deleted scripts/ci/macos-bats-flock-bin/flock; .github/workflows/test-dotfiles.yml no longer asserts flock/shlock. bats' within-file semaphore — the only thing the shim accelerated — has no subject in the codebase anymore.
