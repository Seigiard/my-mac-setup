---
title: "herdr-child: signal race can orphan a tab before pane capture"
short_description: "The launch path still creates the tab or pane, then parses identity, then assigns, so a signal in that window leaves pane and launch_terminal empty; after 47ef76d the helpers are cleanup_pane and owned_launch_signal in home/dot_local/lib/herdr-child-launch.sh, and two gaps remain: tab mode re-parses the buffered response but json_tab_identity emits only pane and tab, so the empty launch_terminal makes cleanup_pane refuse the close and the tab is still orphaned, while pane mode has no fallback at all and the only barrier test fires after the read."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","tab-mode","signal-handling","code-review-residual"]
date: "2026-08-26"
status: "done"
priority: "low"
closed: "2026-09-05"
---

## Why this exists

`start_child` moved out of `home/dot_local/bin/executable_herdr-child` into
`home/dot_local/lib/herdr-child-launch.sh` in `47ef76d` (split child lifecycle
into modules); the bin script is now a 54-line dispatcher. The helpers this
record originally named — `signal_cleanup`, `close_unregistered_pane`,
`split_record`, and the `tests/scripts.bats` suite — do not exist on `main`.
The current names are `owned_launch_signal` (`herdr-child-launch.sh:194`),
`cleanup_pane` (`:166`), and `tests/bashunit/scripts_test.sh`.

The race itself is not fixed. Both launch branches still create the
tab or pane, then parse its identity, then assign:

```bash
split_json="$(herdr "${split_args[@]}")" || { ... }
identity="$(printf '%s' "$split_json" | python3 -c '...')" || { ... }
IFS=$'\t' read -r pane launch_terminal tab <<< "$identity"
```

A signal delivered between the `herdr` call returning and the `read` completing
leaves `pane` and `launch_terminal` empty. Two residual gaps remain:

- **Tab mode recovers the pane but still refuses to close it.**
  `owned_launch_signal` implements the reviewer's suggested buffered re-parse
  (`herdr-child-launch.sh:197-206`), but `json_tab_identity`
  (`herdr-child-runtime.sh:267-277`) extracts the terminal id and then prints
  only `pane\ttab`. `launch_terminal` therefore stays empty, and `cleanup_pane`
  short-circuits at `if [ -z "$launch_terminal" ] || ! pane_terminal_matches ...`
  (`:183`), printing `preserving pane %s; terminal identity changed` and
  returning 1. The tab is still orphaned — now with a message instead of
  silence, and the message names the pane rather than the tab.
- **Pane mode has no fallback at all.** The recovery block is gated on
  `[ "$tab_mode" -eq 1 ]` (`:197`), so in pane mode `pane` stays empty,
  `cleanup_pane` returns 0 at its `[ -n "$pane" ] || return 0` guard (`:168`),
  and nothing is reported.

Coverage does not reach the window. Test 66
(`tests/bashunit/scripts_test.sh:3927`) injects SIGTERM at
`HERDR_CHILD_TEST_TAB_CREATED_BARRIER`, which sits *after* the `read`
(`herdr-child-launch.sh:239-264`), so it exercises the post-capture path only.

Origin: two independent code-review passes (Claude + OpenCode via
`se-code-review`) against commit range `a692fda..1ab1e49` during the tab-mode
work (`docs/plans/2026-08-26-1123-feat-herdr-child-tab-mode-plan.md`).

## Scope

Close the two residual gaps without weakening `cleanup_pane`'s identity
validation for every other caller:

- Have `json_tab_identity` also emit the terminal id it already extracts, and
  have `owned_launch_signal` assign it to `launch_terminal`, so the recovered
  pane passes `cleanup_pane`'s terminal check instead of being preserved.
- Give pane mode the same buffered re-parse from `split_json`, using the
  pane-branch response shape (`result.pane`).
- Add a signal-injection regression test that fires *before* the `read` in both
  modes, mirroring the existing barrier pattern in
  `tests/bashunit/scripts_test.sh`, without introducing a race in the fix.

Out of scope: broader redesigns of the trap/cleanup architecture, or blocking
signals around the `herdr` call.

## Open decisions

- Whether to fix pane mode and tab mode together (recommended, same root cause)
  or tab mode only.
- Whether extending `json_tab_identity` to a three-field record is preferable to
  adding a separate terminal-only accessor, given its other callers.

## Resolution

Fixed. json_tab_identity (home/dot_local/lib/herdr-child-runtime.sh) already extracted and validated the terminal id but printed only pane and tab, so a launcher signaled before it captured its identity recovered a pane with no launch_terminal, and cleanup_pane then refused the close with 'terminal identity changed'. The helper now prints pane, terminal and tab, and a new json_pane_identity gives pane mode the same accessor.

In herdr-child-launch.sh, owned_launch_signal's tab-only inline recovery is replaced by recover_launch_identity, which re-derives pane and launch_terminal from the buffered response for either mode; pane mode previously had no recovery at all and was silent, and now recovers or reports its own diagnostic. Both main launch paths call the shared helpers instead of the inline python duplicates they carried; the tab-mode duplicate was the copy that had already drifted from the helper, so this removes a second source of truth rather than adding a third. The test-only barriers in this path are now one bounded hold_launch_barrier helper, which the pre-existing tab-created barrier also uses.

Coverage: two tests (0801 tab, 0802 pane) park the launcher at a new bounded barrier placed between the herdr response and the identity read, deliver a real SIGTERM there, and take their oracle from the herdr stub's recorded call log and the launcher's real exit status. Each requires 'pane close wT:p9' to appear, requires the process to exit nonzero, and requires that ownership publication ('pane report-metadata', 'agent start') was never reached.

Verified by the orchestrator rather than taken on report: make lint exit 0, make test-issues exit 0, and tests/bashunit/scripts_test.sh 354 passed / 1 skipped / 0 failed. Two mutations confirm the tests can fail and are specific: reverting json_tab_identity to two fields turns only 0801 red with 'terminal identity changed after signal-TERM', and re-gating recover_launch_identity on tab mode turns only 0802 red with the pane-mode diagnostic. The four bounded-barrier tests from the earlier barrier work still pass, which was the real risk in folding their hold into the shared helper.

Left open deliberately: a signal arriving during the herdr command substitution leaves split_json empty, so no shell-side recovery is possible. Neither new test claims to cover that.

Not verified: make test-local could not run. A chezmoi apply from the user's own interactive shell (PID 92614) holds the persistent state lock and was left alone. This change touches only existing non-template .sh files, so it carries no new managed path or template-rendering risk; make test-ubuntu covers the sweep at the end.
