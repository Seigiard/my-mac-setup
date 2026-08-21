---
title: Create a Pi startup updater for Homebrew-managed Pi and Pi packages
type: idea
date: 2026-08-18
status: done
closed: 2026-08-21
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

## Resolution

Closed as already implemented. The extension landed as
`home/dot_pi/agent/extensions/brew-auto-update/index.ts` in commit `1da31ab`
(feat(pi): add Homebrew startup updater), refined by `809dcfd` (notify only when
updates are installed) and `ce8a90c` (keep update checks silent). This audit
mapped every Scope requirement against the code and tests, then re-ran the tests
on 2026-08-21.

Requirement mapping (implementation in `index.ts`, focused tests in
`tests/pi-brew-auto-update.test.ts`, smoke tests in `tests/smoke.bats`):

- **Startup-only trigger** — `pi.on("session_start", ...)` returns early unless
  `event.reason === "startup"`. Test: "registers startup-only background
  execution and the manual command" (a `reload` event runs nothing).
- **Sequential operations** — `UPDATE_STEPS` runs `brew update`, then
  `brew upgrade pi-coding-agent`, then `pi update --extensions`, in order,
  stopping on the first failure. Test: "does not notify when successful commands
  install no updates" asserts the exact call sequence.
- **Forbidden commands** — no bare `pi update`, no `--self`, no npm global
  install, no unscoped brew upgrade. Smoke test "Pi brew auto updater keeps
  package-manager commands scoped" asserts the three allowed argument arrays,
  forbids `"--self"`, `"--all"`, and `command: "npm"`, and counts exactly two
  `brew` and one `pi` command in the source.
- **Restart semantics** — notifications say "Restart Pi to use them", never
  claiming a hot reload (`installedUpdateMessage`).
- **`PI_OFFLINE=1`** — skips all work before touching the lock. Test: "skips all
  network work when PI_OFFLINE is set".
- **`PI_BREW_AUTO_UPDATE=0`** — disables the startup trigger only; the manual
  command still runs. Test: "disables startup only when PI_BREW_AUTO_UPDATE is
  zero".
- **`/brew-auto-update-now`** — registered via
  `pi.registerCommand("brew-auto-update-now", ...)`; runs the same sequence with
  the `manual` trigger.
- **Bounded timeout** — every step runs with `timeoutMs` (default 5 minutes); a
  killed process stops the sequence with a timeout failure message. Test: "stops
  after a timed-out command and reports the failure".
- **Non-aborting failures** — every failure path resolves to a `failed`
  `UpdateResult`; the startup handler wraps the call so no rejection escapes
  into Pi startup. Test: "stops on command failure without aborting the caller".
- **Argument arrays** — `deps.exec(step.command, [...step.args], ...)`; no shell
  interpolation anywhere. Asserted by the command-policy smoke test.
- **Cross-process lock** — atomic `mkdir` lock in
  `$XDG_STATE_HOME/pi/brew-auto-update.lock` with an `owner.json`
  (pid/startedAt/token). A contender reports and continues without waiting;
  stale-owner recovery uses process liveness (`kill -0`) plus a bounded age
  (20 minutes), and release is token-guarded so a replacement lock is never
  deleted. Tests: "reports contention and does not wait for a live owner",
  "recovers a lock whose owner process is dead", "recovers a lock older than the
  bounded stale age", "does not delete a replacement lock while releasing its
  own lock".
- **Smoke coverage** — `tests/smoke.bats` has three tests: deployment with both
  entry points, source-level command policy, and one that runs the focused bun
  suite.

Verification on close: `bun test tests/pi-brew-auto-update.test.ts` — 13 pass,
0 fail; `bats tests/smoke.bats --filter "Pi brew auto updater"` (from the main
checkout, read-only against the deployed `~/`) — 3 ok; `make lint` clean.

Open decisions, as resolved by the implementation: the Homebrew step runs
`brew update` + `brew upgrade pi-coding-agent`; startup fires the update in the
background and Pi becomes usable immediately; the timeout is 5 minutes per step;
the lock lives in `$XDG_STATE_HOME/pi/`; unpinned packages update on every
process start under the single-owner lock.

Known gaps, tracked separately:

- The Docker suite cannot run the focused test — its `../home` import does not
  resolve under the `docker/docker-compose.yml` mount layout, so
  `make test-ubuntu` is red on this test. Pre-existing, tracked as
  `docs/issues/2026-08-21-011-pi-brew-test-unresolvable-path-in-docker.md`.
- The silencing commits (`809dcfd`, `ce8a90c`) removed all per-step UI status,
  and failure results are discarded at both call sites, so a failing updater —
  including an explicit `/brew-auto-update-now` run — is invisible to the user.
  The issue asked for failures to be reported. Filed as
  `docs/issues/2026-08-21-020-brew-auto-update-failures-are-invisible.md`.

Minor gap not filed: the "manual macOS trial with two Pi processes started
concurrently" has no recorded evidence in the repo. The lock-contention and
stale-recovery semantics are covered by four focused tests, so a tracked issue
for a one-off manual trial would not pay for itself.
