---
title: "palette herdr-stub tests flake under parallel load on a busy machine"
short_description: "The R6-family herdr-stub tests in palette_test.sh intermittently fail at -j 8 when the machine is heavily loaded, because palette.py's HERDR_CALL_TIMEOUT_SECONDS = 2 is an idle-machine wall-clock bound rather than a state-aware wait."
type: "bug"
category: "command-palette"
tags: ["flake","semantic-tests"]
date: "2026-09-02"
status: "open"
priority: "low"
---

## Why this exists

Observed during the 2026-09-02 tautology audit: an unmodified HEAD copy of tests/bashunit/palette_test.sh in a scratch tree failed 1, 6, 5 and 7 tests across four consecutive 'tests/lib/bashunit -j 8' runs while four coding agents ran concurrently (load average 10-16). The failures are in the R6 herdr-stub family and are timeouts against palette.py's HERDR_CALL_TIMEOUT_SECONDS = 2. The flake is pre-existing and independent of that audit's changes. It did not reproduce in three consecutive -j 8 runs at load average 7-10 after the agents finished, so the threshold is somewhere above that. This matches docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md.

## Scope

Replace the fixed two-second wall-clock bound with a state-aware wait in the test harness, or make the stub signal readiness so the test waits on an observable condition instead of elapsed time. Do not simply raise the constant: a larger idle-machine bound is the same latent flake with a longer fuse. Leave palette.py's production timeout alone unless the same reasoning applies to real herdr calls.

## Open decisions

Whether the bound belongs in the test harness only, or whether palette.py's own HERDR_CALL_TIMEOUT_SECONDS should become configurable so the suite can raise it without changing shipped behaviour.
