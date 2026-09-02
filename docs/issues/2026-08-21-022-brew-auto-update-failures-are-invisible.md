---
title: "The Pi brew auto-updater never surfaces a failure, even on manual invocation"
short_description: "Both Pi updater entry points discard failed results, and focused tests explicitly require empty notifications for timeout and command failure, so the suite protects the user-visible defect instead of detecting it."
type: "follow-up"
category: "agent-platform"
tags: ["agent-platform","follow-up"]
date: "2026-08-21"
status: "open"
priority: "medium"
---

## Why this exists

`home/dot_pi/agent/extensions/brew-auto-update/index.ts` runs `brew update`,
`brew upgrade pi-coding-agent`, and `pi update --extensions` on Pi startup and
via `/brew-auto-update-now`. Commits `809dcfd` and `ce8a90c` deliberately
silenced the success path: no per-step status, one notification only when
something actually updated. That silencing also swallowed the failure path:

- `runBrewAutoUpdate` returns a `{ status: "failed", message }` result, but both
  call sites discard it — the `session_start` handler fires it with
  `void ...catch(() => {})`, and the `brew-auto-update-now` handler awaits it
  and drops the result.
- `ui.notify` is only ever called for the installed-updates message;
  `UpdateUi.setStatus` is declared but never called at all (the focused tests
  assert `statuses` stays empty).
- `tests/pi-brew-auto-update.test.ts:276-305` explicitly requires
  `notifications` to stay empty after both a timeout and a nonzero command
  result. The suite therefore protects the defect instead of changing verdict
  when failure reporting is absent.

So a broken updater — an expired Homebrew, a failing `pi update --extensions`, a
persistent timeout — fails silently on every startup forever, and a user who
explicitly runs `/brew-auto-update-now` gets no output either way. The origin
spec (`docs/issues/2026-08-18-028-create-pi-brew-and-extension-startup-updater.md`)
required that UI status "reports failures without aborting Pi startup"; the
non-aborting half is implemented, the reporting half is not.

## Scope

- `home/dot_pi/agent/extensions/brew-auto-update/index.ts` — surface the
  `failed` (and for the manual command, also `skipped`/`contended`/up-to-date)
  result message through `ui.notify`.
- `tests/pi-brew-auto-update.test.ts` — replace the empty-notification
  assertions with consumer-visible failure notifications. Require the manual
  command to report every terminal outcome and cover the selected startup
  notification policy with a nearby control.
- Demonstrate the red state by running the focused test against the current
  silent behavior, then require green after failure reporting is implemented.

Invoking the registered manual handler and proving that it starts the update
sequence belongs to `2026-09-01-004`; this issue owns what the user sees after
that sequence reaches a terminal result.

## Open decisions

Both decisions below are settled; this section records the chosen policy.

- **Startup notification policy: notify every time, no rate-limiting.** A
  failed startup update surfaces a `ui.notify` on every startup it fails, with
  no lock-state window, no persisted state, and no other rate-limiting. Silence
  is the defect this issue fixes, and a rate-limit would add state that can
  hide a persistent break instead of surfacing it. Success stays silent at
  startup unless something was actually updated (unchanged from `809dcfd` /
  `ce8a90c`). The manual command always reports its terminal outcome —
  `failed`, `skipped`, `contended`, up-to-date, and updated — regardless of
  whether anything changed.
- **Notification level for failures: `warning`.** This matches the convention
  already used by `home/dot_pi/agent/extensions/agents-local` for a
  degraded-but-not-fatal condition. The manual command's non-failure terminal
  outcomes (`skipped`, `contended`, up-to-date, updated) notify at `info`.
