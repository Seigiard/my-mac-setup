---
title: "herdr-child: signal race can orphan a tab before pane capture"
short_description: "In start_child, INT/TERM delivered between herdr tab create returning and the pane/terminal read (IFS read -r tab_id pane terminal <<< \"$split_record\") leaves $pane empty, so close_unregistered_pane's [ -n \"$pane\" ] guard no-ops and the newly created tab (with its one pane) is orphaned; the pane-mode pane-split path has the same narrow window (pre-existing, not new), autofix_class is manual per code review, and fixing it needs the create response buffered for signal_cleanup to re-parse rather than a small patch."
type: "follow-up"
category: "herdr"
tags: ["herdr-child","tab-mode","signal-handling","code-review-residual"]
date: "2026-08-26"
status: "open"
priority: "low"
---

## Why this exists

`start_child` in `home/dot_local/bin/executable_herdr-child` (tab-mode branch, `docs/plans/2026-08-26-1123-feat-herdr-child-tab-mode-plan.md`) creates the child's tab, then parses its pane/terminal identity out of the response before assigning the function-local `pane`/`terminal` variables:

```bash
split_json="$(herdr "${split_args[@]}")" || { ... }
split_record="$(printf '%s' "$split_json" | python3 -c '...')"
IFS=$'\t' read -r tab_id pane terminal <<< "$split_record"
```

`signal_cleanup` is trapped on `INT TERM` for the whole function. If a signal lands after `herdr tab create` has already created the tab but before the `read -r` line completes, `pane` is still `""` (its initial value from the function's `local` declarations). `close_unregistered_pane`'s first line is `[ -n "$pane" ] || return 0`, so cleanup silently does nothing and the newly created tab — with its one live pane — is left running with no agent ever started in it.

The same structural gap exists in the pre-existing pane-mode `pane split` branch (identical shape: subprocess call, then parse, then assign). It was never flagged or fixed there, so this is a narrow, inherent bash-trap timing limitation rather than a regression specific to `--tab`. Two independent code-review passes (Claude + OpenCode via `se-code-review`, run against commit range `a692fda..1ab1e49` plus follow-up fixes) surfaced it during the tab-mode work; see `home/dot_local/bin/executable_herdr-child` around the `tab create` branch of `start_child`.

## Scope

Make `signal_cleanup` able to recover and close (or at least report) a tab/pane created in this narrow window, without weakening its existing identity-validation guarantees for every other case. The reviewer's suggested direction: keep the raw `herdr tab create` (or `pane split`) response around (e.g. in a variable set before the parse, not only after), and have `signal_cleanup` fall back to parsing that raw response for a pane id when the normal `pane`/`terminal` variables are still empty, then run the same validated close path. Add a signal-injection regression test (mirroring the existing `STUB_START_BLOCK`/`hpl_wait_for_file` pattern in `tests/scripts.bats`) that delivers the signal in this specific window for both pane-mode and tab-mode, proving the fix without introducing a race in the fix itself.

Out of scope: broader redesigns of the trap/cleanup architecture, or blocking signals around the `herdr` call (a bigger behavior change with its own tradeoffs, not requested by the review).

## Open decisions

- Whether to fix this for both pane-mode and tab-mode together (recommended, since it's the same root cause) or tab-mode only.
- Exact mechanism for making the raw response available to `signal_cleanup` without holding it in a shell variable for the whole function lifetime (a temp file vs. a wider-scoped variable).
