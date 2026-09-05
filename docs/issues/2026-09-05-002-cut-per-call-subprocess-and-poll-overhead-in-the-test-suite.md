---
title: "Cut per-call subprocess and poll overhead in the test suite"
short_description: "Six independently measured items each cost seconds per scripts_test.sh run: python3 per JSON field read in herdr-child-runtime.sh (~18.5 CPU-s), a sleep 1 poll in the context-threshold hook (~21.5 s wall), palette_test.sh discarding its Python bytecode cache per test (-10.8 CPU-s measured A/B), sleep 0.2 in run_npx, a sleep 1 pane-busy retry, and hpl_setup rewriting invariant stub scripts 107 times per run (-20 CPU-s on test-macos)."
type: "chore"
category: "testing-ci"
tags: ["performance","poll-interval","fork-overhead"]
date: "2026-09-05"
status: "done"
priority: "medium"
closed: "2026-09-05"
---

## Why this exists

Separate from the copy-pasted encode and read helpers in issue 2026-09-05-001, six independently measured items each cost seconds per run. They share no single root cause, so each stands alone.

| Item | Site | Measured cost |
|---|---|---|
| `python3 -c` per JSON field read | `home/dot_local/lib/herdr-child-runtime.sh`, 889 pure-accessor calls | ~18.5 CPU-s; 20.54 to 3.37 ms per call when rewritten as `jq` |
| `sleep 1` poll in the threshold hook | `home/private_dot_claude/hooks/executable_context-threshold.sh` lines 80, 89 | ~21.5 s wall across twelve tests |
| Python bytecode cache discarded per test | `tests/bashunit/palette_test.sh:33` | -10.8 CPU-s and -22% wall, A/B over three repetitions |
| `sleep 0.2` poll in `run_npx` | `home/dot_local/bin/executable_skills:129` | ~6.6 s wall, 35 fires |
| `sleep 1` pane-busy retry | `home/dot_local/lib/herdr-child-launch.sh:322` | ~4.9 s wall, 5 fires |
| Invariant stub scripts rewritten per call | `tests/helpers/herdr_pane_labels.bash:62`, 107 calls per run | -2 CPU-s on test-ubuntu, -20 CPU-s on test-macos |

The generalizable defect behind the three sleep items: the timeout is already injectable in each case (`CONTEXT_USAGE_EXTRACTION_TIMEOUT`, `SKILLS_TIMEOUT`), but the poll interval that implements it is a hardcoded literal that doubles as the clock (`waited=$((waited + 1))`, `tick / 5`). Converting those loops from counting iterations to comparing elapsed time is what makes the interval independently shrinkable.

## Scope

Make each poll interval injectable and drive its bound off elapsed time rather than an iteration count, then set the interval low in the test helpers while leaving every timeout constant untouched. The tests that prove a timeout path must keep burning their real budget and still return 124.

Rewrite the pure-JSON accessors in `herdr-child-runtime.sh` as `jq`, which is already a hard dependency. The 193 calls that do real file locking through `fcntl` must stay Python.

Give `palette_test.sh` a file-scoped bytecode cache in `set_up_before_script` instead of a per-test one, keeping the cache outside the source tree so the read-only Docker mount still works. The same one-line change applies at `tests/bashunit/smoke_test.sh:588` and `:650`.

Build the four invariant stub scripts once per file rather than per test.

Each item lands and is measured separately. An earlier prediction of ~15 s from memoising `hpl_socket_dir` measured exactly zero (288.2 against 288.0 CPU-s) because the suite is idle-bound at 0.30 of ten cores, so arithmetic extrapolation from fork counts is not evidence here.

## Open decisions

Two candidates are deliberately excluded until someone re-measures them. `hpl_set_pane` fans one small document out to sixteen `jq` forks (`tests/helpers/herdr_pane_labels.bash:560`); the slice rewrite measures 47.99 to 9.26 ms, but the agent that proposed it flagged the whole-suite figure as an upper bound after the `hpl_socket_dir` null result. And `HPL_GIT_BUDGET=2` is burned in full by three pane-labels tests, but there the wait is the behaviour under test and the helper comment at `herdr_pane_labels.bash:690` records two prior flakes from exactly that calibration.

## Resolution

Five of the six measured items landed. Three wait loops now take their budget from SECONDS and expose the poll interval as an override, so tests shorten sampling without moving deadlines: the context-threshold hook (8.98s to 6.22s on its family), run_npx and terminate_tree in the skills wrapper (3.90s to 3.61s), and the child launcher's pane-busy retry. palette_test.sh keeps a per-file Python bytecode cache (20.4 to 8.93 CPU-seconds, 6.71s to 5.40s wall). The pane-labels harness writes its four invariant stub scripts and its jq lookup once per file and links them into each test, taking that family from 58.3/59.1/57.6s to 54.4/52.1/53.3s across an interleaved three-pair A/B. The child-launcher retry measured no wall-clock win under -j 8 because its sleeps overlap other tests; it is kept as correct, not as a saving. The sixth item, rewriting the pure-JSON accessors in herdr-child-runtime.sh from python3 to jq, was declined: jq appears nowhere in the herdr-child code and python3 must stay for the 193 fcntl-locking calls, so the swap would add a second hard dependency to the agent launch path rather than replace one.
