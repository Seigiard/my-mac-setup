---
title: "Replace fork chains in state encode and read helpers"
short_description: "encode_key, encode_value, read_state_field, and record_number fork 3-4 processes per call and are copy-pasted across five deployed shell files, costing roughly 13,000 spawns per scripts_test.sh run; a patched-tree A/B measured 276.5 to 241.7 CPU-seconds (-12.6%) with 335/336 tests still passing."
type: "chore"
category: "testing-ci"
tags: ["performance","fork-overhead","shell-hot-path"]
date: "2026-09-05"
status: "open"
priority: "high"
---

## Why this exists

Four independent investigations of the `test-ubuntu` job converged on one cost: the shell libraries fork three to four processes to do string and file work that bash 3.2 does in-process. `scripts_test.sh` spends more time in `sys` than in `user` (198s against 106s on a ten-core host), so it behaves as a process-creation benchmark rather than a computation benchmark.

Four helper shapes are copy-pasted across five deployed files.

| Helper | Processes per call | Calls per pane-labels subset |
|---|---|---|
| `encode_value` | 3 (`printf`, `base64`, `tr`) | 4357 |
| `encode_key` | 4 (`printf`, `base64`, `tr`, `tr`) | 3279 |
| `read_state_field` | 4 (`grep`, `cut`, then `printf`, `base64 -d`) | 2912 |
| `record_number` | 3 (`sed`, `head`, plus the outer substitution) | 1909 |

Sites:

- `home/dot_local/bin/executable_herdr-pane-labels` lines 115, 119, 148, 269
- `home/dot_local/lib/herdr-worktree-state.sh` lines 6, 10, 36, 44
- `home/dot_local/lib/context-usage.sh` lines 64, 68, 103
- `home/dot_local/lib/herdr-child-runtime.sh` line 284 (`state_value`)
- `home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh` lines 75, 79, 83, where `hpl_cutover_raw_field` greps the same file twice per field

`read_state_field` runs seven times per pane from `resolve_pane_location` and eight times per pane from `location_state_matches`, so a file of at most ten lines is grepped eight times to compare eight fields.

Evidence: patching a throwaway copy of the tree and rerunning measured 276.5 to 241.7 CPU-seconds, a 12.6% reduction, with wall time 97.3 to 90.4 seconds and 335 passed / 1 skipped, no behavioural differences. Per subset: pane-labels 144.4 to 127.2, worktree-identity 45.2 to 40.0, context-usage 4.6 to 2.9. The `herdr-child` subset was unchanged at 49.9 to 49.5 because it is wait-bound; that cost belongs to issue 2026-09-05-002.

## Scope

In all five files:

- Replace the translate chains with bash parameter expansion: `${e//$'\n'/}`, `${e//\//_}`, `${e//+/-}`, `${e//=/}`. The character classes `/+` and `=\n` are disjoint, so reordering translate and delete cannot change the output.
- Replace `grep -m1 "^${key}=" | cut -d= -f2-` and `sed -n "s/^${key}=//p" | head -1` with one `while IFS= read -r line || [ -n "$line" ]` scan plus `${line#*=}`. Keys are literal identifiers, so losing grep regex semantics is not observable, and the `|| [ -n "$line" ]` guard preserves a final line without a trailing newline.
- Replace the second `grep -c` in `hpl_cutover_raw_field` with a counter inside the same scan.

Fold in the same-shape one-liners found alongside: `atomic_write` forking `dirname` in four copies and running an unconditional `mkdir -p`; the `ps | sed` trims in `process_start_token`; and the unmemoised `encode_key` in `herdr-worktree-state.sh`, whose sibling at `executable_herdr-pane-labels:123` already memoises with exactly that rationale in its comment.

Every path here is chezmoi-managed and deployment-sensitive, so `docs/agent-verification.md` governs the gate: `make test-ubuntu`.

## Open decisions

Whether to also collapse `$(namespace_dir)` at its eighteen call sites into a variable set once in the mode prologue. The fork count is exact at 2898 subshells per run, but the A/B was swamped by host noise of plus or minus 14 CPU-seconds against a predicted 2.5-second gain. Treat it as a correctness-neutral tidy, not a proven win.
