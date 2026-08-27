---
title: "Playground identity checks flake under full-suite CPU load"
short_description: "The viewer minimum-dimensions bats case (and occasionally other playground cases) intermittently fails full-suite runs with PROCESS_IDENTITY_MISMATCH reaching cleanup-incomplete, passes in isolation, and reproduces on the pre-U7 baseline, indicating load-sensitive process-identity verification rather than a regression."
type: "bug"
category: "testing-ci"
tags: ["flaky-test","herdr-git-status-playground"]
date: "2026-08-27"
status: "open"
priority: "medium"
---

## Why this exists

Full runs of `bats tests/scripts.bats` intermittently fail one playground case — most often `enforces minimum equal terminal dimensions and marks a shrunk view diagnostic until restored` — with `PROCESS_IDENTITY_MISMATCH` ("owned resource cleanup could not be proved") and the run landing in `cleanup-incomplete`. The same case passes in isolation every time. During U7 verification the flake reproduced on the pre-U7 baseline as well (two of five full runs, a different test each time), so this is load-sensitive behavior in the process-identity verification path (`verify_process` reading the live command line via `ps` while teardown races process exit), not a regression from any single unit.

Impact: an otherwise green branch can show a spurious single-test failure in full-suite runs on a loaded machine; CI or local reruns then pass, costing rerun time and eroding trust in the suite.

## Scope

- Reproduce under controlled CPU load and capture which `verify_process` read races which teardown step.
- Make the identity check tolerant of the benign race (e.g. re-probe once on mismatch when the process has exited between reads) without weakening the ownership guarantee for genuinely mismatched processes.
- Prove the fix with a loaded-run regression check; keep the isolation-run behavior unchanged.

## Open decisions

None.
