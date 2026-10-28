---
title: Adopt upstream Herdr Wakeup
status: accepted
date: 2026-09-17
supersedes: []
---

# ADR-0016: Adopt upstream Herdr Wakeup

## Context

This repository carried a modified copy of
[`triggerNZ/herdr-caffeinate`](https://github.com/triggerNZ/herdr-caffeinate/tree/fcbed77bd4b82f646082c1ffb45d7b4ac242eb1a).
The local change kept the assertion for 1200 seconds after the final working
agent became quiet. Repeated idle events preserved the original deadline,
renewed activity restored the indefinite assertion, and zero seconds released
immediately. Keeping the copy here also made dotfiles own process lifecycle,
locking, tests, documentation, and Herdr compatibility.

The alternatives were rechecked at immutable revisions on 2026-09-17:

| Option | Activity and linger behavior | Cleanup, configuration, and dependencies | Maintenance and license |
|---|---|---|---|
| [`triggerNZ/herdr-caffeinate`](https://github.com/triggerNZ/herdr-caffeinate/tree/fcbed77bd4b82f646082c1ffb45d7b4ac242eb1a) | Reconciles the aggregate agent list on status events, but [releases immediately](https://github.com/triggerNZ/herdr-caffeinate/blob/fcbed77bd4b82f646082c1ffb45d7b4ac242eb1a/lib.sh#L110-L119) and has no linger setting. | Tracks one `caffeinate` PID, normally binds it to Herdr with `-w`, and exposes awake states and flags through sourced shell configuration. Disable and unlink do not stop an existing assertion. Requires macOS shell tools; `jq` is optional. | Declares macOS and Herdr >= 0.7.0; no macOS release floor is documented. One commit, no tags, releases, CI, tests, or [declared license](https://github.com/triggerNZ/herdr-caffeinate/tree/fcbed77bd4b82f646082c1ffb45d7b4ac242eb1a). |
| [`nwarwick/herdr-caffeinate`](https://github.com/nwarwick/herdr-caffeinate/tree/25bdfe36d3948123069c9dadbb02df4d1a895d07) | A per-session monitor aggregates agents and [keeps the first idle timestamp](https://github.com/nwarwick/herdr-caffeinate/blob/25bdfe36d3948123069c9dadbb02df4d1a895d07/scripts/monitor.sh#L59-L81), so repeated idle samples do not extend its configurable grace period and work resumption cancels release. Zero grace still needs a later poll before release. | Owns and restarts one `caffeinate -i -w` child, bounds Herdr requests, and exits after repeated failures. Configuration is a simple `settings.conf`; display wakefulness is not configurable. | Declares macOS and Herdr >= 0.7.5; no macOS release floor is documented. MIT with a lifecycle test, but one commit, no CI, tags, or releases. |
| [`Chida82/herdr-caffeinate-keeper`](https://github.com/Chida82/herdr-caffeinate-keeper/tree/c49cb3696ab793d2e37d29a1e67fa0fb14f4c166) | Aggregates workspace status, preserves a fixed 12-second idle deadline, resumes on activity, and also reports external keep-awake processes in the sidebar. The linger duration and flags are fixed. | Owns one monitor and assertion per session and tests lifecycle cleanup, but adds sidebar metadata behavior that is unrelated to this need. | Declares macOS/Linux and Herdr >= 0.9.0; no OS release floors are documented. MIT with tests and CI configuration, but one commit, no release, and its only recorded CI run failed. |
| [`BoKleynen/herdr-caffeinate`](https://github.com/BoKleynen/herdr-caffeinate/tree/14c63d711582a5318b89f760b5ecd52f53ef1820) | Aggregates per-pane socket events but releases immediately; it has no linger configuration. | Owns one Rust child process and cleans it up on shutdown. Requires Cargo to install. | Declares macOS and Herdr >= 0.7.0; no macOS release floor is documented. Several recent commits, but no license, release, CI, or linger coverage. |
| [`usrivastava92/herdr-wakeup`](https://github.com/usrivastava92/herdr-wakeup/tree/43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04) | Its [explicit state machine](https://github.com/usrivastava92/herdr-wakeup/blob/43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04/crates/wakeup-herdr/src/state.rs#L186-L231) aggregates matching agents, records one pending-sleep timestamp, cancels release when activity resumes, and accepts zero start and stop grace. [Behavior tests](https://github.com/usrivastava92/herdr-wakeup/blob/43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04/crates/wakeup-herdr/src/state.rs#L260-L342) cover sustained idle and interrupted grace. | Owns one watcher and assertion per Herdr session, validates PIDs, restarts a failed assertion, releases on stop/shutdown, and exits after prolonged Herdr failure. JSON config covers statuses, display wakefulness, grace periods, notifications, arming, and autostart. It builds a private Rust watcher and bundles verified `wakeup` binaries. | Declares macOS/Linux and Herdr >= 0.7.0; no OS release floors are documented. MIT, tagged `v0.1.0`, active release/vendor workflows, and green CI at the selected post-release revision. |

## Considered options

- Keep the modified implementation in dotfiles.
- Contribute linger support to the unlicensed origin.
- Adopt one of the simpler shell plugins and accept fixed flags or weaker
  release and cleanup behavior.
- Adopt Herdr Wakeup and express the existing behavior through its supported
  configuration.

## Decision

Adopt `usrivastava92/herdr-wakeup` at reviewed commit
`43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04`. This revision follows release
`v0.1.0` and adds default autostart plus serialized watcher startup. Its CI
completed successfully at that commit. Install it with:

```sh
herdr plugin install usrivastava92/herdr-wakeup/plugin \
  --ref 43db0b9f88a4b1bc560593b0ce8f2a7d2a940f04 -y
```

Keep personal policy in the chezmoi-managed
`~/.config/herdr/plugins/config/herdr-wakeup/config.json`: work starts the
assertion without a grace delay, the display remains awake, only `working`
counts as active, the final quiet transition lingers for 1200 seconds, and the
plugin's own notifications remain disabled. Herdr Wakeup scopes runtime config
by socket-derived session key, so the apply script links both the default
socket and the currently inherited `HERDR_SOCKET_PATH`, when different, to that
managed policy before starting the watcher. Named sessions created after apply
retain upstream defaults until a later apply runs from that session. The policy
file, rather than the plugin's `arm` and `disarm` actions, owns persistent
arming; a later apply restores the link if an action replaces it.

The one-time cutover installs, configures, and enables the replacement before
it asks the old `keepawake.caffeinate` action to release its assertion. It then
disables the old hook, reloads Herdr, and requires the replacement's own start
action to confirm its watcher is live before unregistering the old ID and
removing the local implementation. Activation failure re-enables, reloads, and
reconciles the local implementation, then checks its status before claiming a
successful rollback. Regular updates require the current session's watcher to
stop before replacing package binaries, relink policy, reload Herdr, and start
the watcher again. Updates with several active named sessions require stopping
those sessions explicitly first, matching upstream's cleanup contract.

The package is outside the auto-update trust list. Updating means reviewing a
new upstream release or revision, confirming green upstream CI and vendored
binary provenance, and changing the immutable commit pin here. Removal is:

```sh
herdr plugin action invoke stop --plugin herdr-wakeup
herdr plugin uninstall herdr-wakeup
```

Run the stop action in every active Herdr session, then remove the managed
policy only when no future reinstall should inherit it.

## Consequences

The plugin installs without this checkout and dotfiles no longer owns its
manifest, Rust implementation, process helpers, behavioral tests, or release
pipeline. Cargo was already a declared macOS dependency for pinned
source-distributed Herdr plugins. The package's separate `wakeup` binary stays
private to the plugin and does not add a command to the user's PATH.

This repository verifies only deployment behavior: immutable installation,
transactional local-to-GitHub cutover, managed policy linkage, and disposable
home application. Upstream tests own working-to-quiet-to-linger-to-release,
duplicate idle events, activity resumption, zero grace, process restart, and
cleanup semantics.

CI cannot prove a macOS power assertion. After deploying on a Mac, record a
separate live check: run `herdr plugin action invoke doctor --plugin
herdr-wakeup`, observe `pmset -g assertions` while an agent is working, after
it becomes quiet, after a second idle event, after work resumes, and after the
1200-second deadline, then run the stop action and confirm no plugin-owned
assertion or watcher remains. Do not report the Docker deployment gate as that
macOS evidence.
