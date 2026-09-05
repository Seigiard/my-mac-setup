---
title: "build_worktree_tokens grows super-linearly with worktree count"
short_description: "executable_herdr-pane-labels:638 forks awk once per pair of checkout roots while resolving unique path suffixes, measured at n^1.7 (6 roots 240ms, 12 roots 720ms, 24 roots 2400ms); it costs only ~2.5 CPU-s in CI but the sweep daemon pays it on every pass and already sits near 9% CPU at rest."
type: "chore"
category: "herdr"
tags: ["performance","algorithmic-complexity","sweep-daemon"]
date: "2026-09-05"
status: "open"
priority: "medium"
---

## Why this exists

`build_worktree_tokens` at `home/dot_local/bin/executable_herdr-pane-labels:638` is the only genuinely super-linear function in the repository. It resolves the shortest unique slash suffix for each checkout root by rescanning every other root at each suffix depth, forking `awk` through `path_suffix` once per comparison. Instrumentation confirms the fork count is exactly n squared: 36 at n=6, 144 at n=12, 576 at n=24.

Measured on an idle host with the colliding-basename shape:

| Roots | 1 | 2 | 3 | 6 | 12 | 24 | 48 |
|---|---|---|---|---|---|---|---|
| CPU-ms | 4.8 | 9.0 | 14.6 | 240 | 720 | 2400 | ~7900 |

That is roughly n^1.7, tripling per doubling.

CI barely notices it: 106 of the 108 calls per suite run have three or fewer roots, so the total is about 2.5 CPU-seconds, most of it in the two location passes of `scripts_test.sh:6221`. The reason to fix it is the running daemon. `herdr-pane-labels --sweep-daemon` sits near 9% CPU at rest, and at 24 worktrees this one function costs 2.4 seconds on every sweep pass.

Secondary, same function: `text_prefix` forks a `printf` and `cut` pair inside the digest-length retry loop at lines 680 to 695, even though the values it needs are prefixes of one already-computed string.

## Scope

Replace the per-comparison `path_suffix` forks with a single `awk` pass over the whole root list that emits, for every root, the shortest suffix of at least two components that no other root shares. `awk` has real hash tables, so one associative count over the suffixes at each depth gives the same selection rule with one fork instead of n squared.

Compute the digest prefixes once per root instead of forking `cut` inside the retry loop.

The selection rule must not change: the existing tests, in particular `scripts_test.sh:6221` with its twelve roots sharing a basename and one forced digest, define the expected tokens and must pass unchanged.

`executable_herdr-pane-labels` is chezmoi-managed and deployment-sensitive, so `docs/agent-verification.md` governs the gate.

## Open decisions

None.
