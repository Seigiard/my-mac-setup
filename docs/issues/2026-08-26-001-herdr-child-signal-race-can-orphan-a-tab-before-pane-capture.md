---
title: "herdr-child: signal race can orphan a tab before pane capture"
short_description: "The launch path still creates the tab or pane, then parses identity, then assigns, so a signal in that window leaves pane and launch_terminal empty; after 47ef76d the helpers are cleanup_pane and owned_launch_signal in home/dot_local/lib/herdr-child-launch.sh, and two gaps remain: tab mode re-parses the buffered response but json_tab_identity emits only pane and tab, so the empty launch_terminal makes cleanup_pane refuse the close and the tab is still orphaned, while pane mode has no fallback at all and the only barrier test fires after the read."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","tab-mode","signal-handling","code-review-residual"]
date: "2026-08-26"
status: "open"
priority: "low"
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
