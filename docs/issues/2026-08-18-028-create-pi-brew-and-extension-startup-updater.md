---
title: Create a Pi startup updater for Homebrew-managed Pi and Pi packages
type: idea
date: 2026-08-18
status: open
---

## Why this exists

Pi is installed through Homebrew in `home/private_dot_config/brewfiles/Brewfile` as
`brew "pi-coding-agent"`. The third-party `eiei114/pi-auto-update` extension runs
`pi update --extensions` followed by `pi update` at process startup. That self-update path is a bad
fit for this machine because Pi can classify its Homebrew Cellar layout as an npm-style install and
write outside Homebrew's package-management lifecycle.

The useful behavior is still valid: each new Pi process should check for a newer Homebrew-managed Pi
version and refresh installed Pi packages. A local extension can preserve that behavior while keeping
Homebrew authoritative for the Pi executable.

## Scope

Create a local Pi extension under `home/dot_pi/agent/extensions/` that runs once for every new Pi
process on `session_start` when `event.reason === "startup"`.

The updater must run these operations sequentially:

1. Refresh Homebrew metadata and update the `pi-coding-agent` formula through Homebrew.
2. Run `pi update --extensions` to update unpinned Pi packages and reconcile pinned package sources.

The extension must never run bare `pi update`, `pi update --self`, npm global installation, or an
unscoped Homebrew upgrade of every installed formula and cask unless that broader behavior is
explicitly selected later.

The process that initiated the update continues with its already-loaded Pi and extension code. Any
new Pi or extension version becomes authoritative on the next Pi process start. The extension must
state this clearly instead of claiming that the current process hot-reloaded the update.

Add these controls:

- `PI_OFFLINE=1` skips all network update work.
- `PI_BREW_AUTO_UPDATE=0` disables the startup updater without removing the extension.
- `/brew-auto-update-now` runs the same sequence manually.
- A bounded timeout prevents a Homebrew or package update from hanging Pi indefinitely.
- UI status identifies the active step and reports failures without aborting Pi startup.
- Commands run through argument arrays, not shell interpolation.

Add cross-process locking because several Pi processes can start concurrently in different Herdr
panes. Exactly one process may run Homebrew or Pi package updates at a time. A second process must
report that another update owns the lock and continue startup; it must not wait indefinitely or run a
competing package-manager process. The lock needs stale-owner recovery based on process liveness and
a bounded age.

Add smoke coverage in `tests/smoke.bats` for deployment and source-level command policy. Add focused
tests for startup-only execution, environment skips, step ordering, timeout handling, failure
reporting, lock contention, and stale-lock recovery. Include a manual macOS trial with two Pi
processes started concurrently.

## Open decisions

- Whether the Homebrew step should run `brew update` plus `brew upgrade pi-coding-agent`, or use a
  narrower command that asks Homebrew to upgrade only the formula without refreshing all metadata.
- Whether startup should wait for the winning updater to finish or let the update run in the
  background while Pi becomes usable. Waiting gives deterministic status; background execution
  reduces startup latency but requires durable completion reporting.
- The timeout for Homebrew and Pi package updates.
- The stale-lock location and ownership contract. The implementation should prefer an XDG state or
  cache directory rather than a project-local file.
- Whether unpinned Pi packages should update on every process start or use a short cross-process
  freshness window after the first successful update. The requested default is every process start,
  subject to the single-owner lock.
