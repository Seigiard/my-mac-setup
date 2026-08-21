---
title: "The Pi brew auto-updater never surfaces a failure, even on manual invocation"
short_description: "The Pi brew auto-updater never surfaces a failure, even on manual invocation"
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
- `tests/pi-brew-auto-update.test.ts` — extend the failure and manual-command
  tests to assert the notification.

## Open decisions

- Whether startup failures should notify every time or be rate-limited (e.g.,
  once per lock-state window), so a persistently broken Homebrew does not nag on
  every Pi start. The manual command should always report its outcome.
- Notification level for failures: `warning` vs `error`.
