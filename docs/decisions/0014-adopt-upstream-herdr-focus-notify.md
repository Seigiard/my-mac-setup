---
title: Adopt upstream Herdr Focus Notify
status: accepted
date: 2026-09-16
supersedes: []
---

# ADR-0014: Adopt upstream Herdr Focus Notify

## Context

This repository carried a Python reimplementation of Focus Notify because the
upstream plugin required a Rust build and `alerter` from a third-party Homebrew
tap. The local copy sent `blocked` and `done` notifications through
`terminal-notifier` and focused a pane with `herdr agent focus` when clicked.
It also made this dotfiles repository responsible for notification behavior,
tests, diagnostics, and Herdr compatibility.

The comparison was repeated against sources current on 2026-09-16:

| Option | Fit | Dependencies and compatibility | Ownership and maintenance |
|---|---|---|---|
| [`yankewei/herdr-focus-notify` v0.5.1](https://github.com/yankewei/herdr-focus-notify/tree/560e70c5e1716fa0781b6746821ce8676f70a811) | Sends `blocked` and `done` notifications, learns a terminal per workspace, and on click activates that terminal, focuses the agent, then focuses the returned tab. The tab step specifically restores targeting on Herdr 0.9.0. A workspace must first receive a normal pane-focus event so the plugin can learn its terminal; without that binding, clicks deliberately do nothing. | macOS, Herdr >= 0.7.5, Cargo at install time, and [`alerter`](https://github.com/vjeantet/alerter). The [manifest](https://github.com/yankewei/herdr-focus-notify/blob/560e70c5e1716fa0781b6746821ce8676f70a811/herdr-plugin.toml) declares the build and event hooks. | Active releases through [v0.5.1](https://github.com/yankewei/herdr-focus-notify/releases/tag/v0.5.1), behavior and CLI tests, and [macOS CI](https://github.com/yankewei/herdr-focus-notify/blob/560e70c5e1716fa0781b6746821ce8676f70a811/.github/workflows/ci.yml). Package metadata declares MIT and bundled icons carry their own notices. |
| Local `seigi.focus-notify` | Meets the basic notification contract, but only issues `herdr agent focus`; that is insufficient to project the target tab into Herdr 0.9.0 clients. Terminal choice is a fixed default or local config file. | macOS, Python, and `terminal-notifier`. | Every Herdr behavior change must be diagnosed and maintained here. |
| [`A1exthegreat/herdr-agent-notify`](https://github.com/A1exthegreat/herdr-agent-notify/tree/5ba0cab55b99b727cbf973952e3c4c84f12728a5) | Sends status notifications but does not provide click-to-focus targeting. | Windows, Node.js >= 18, Herdr >= 0.8.0. | MIT, tests present, but the platform and interaction contract do not match. |
| [`ProjectAJ14/herdr-warp`](https://github.com/ProjectAJ14/herdr-warp/tree/c66d92bf43d4e45d7e952fd2fc68cdba10c932d5) | Covers `blocked` and `done`, but a notification click can only activate Warp; the user must invoke Herdr targeting separately. | macOS, Warp, Python, Herdr >= 0.8.0. | MIT and tagged releases, but intentionally Warp-specific. |

The former dependency objections are smaller than the ongoing cost and
compatibility risk of owning a second implementation. Upstream now covers the
required terminal selection and correct Herdr 0.9.0 targeting, and keeps its
behavioral tests with the implementation.

Notification hook commands are detached by Herdr. Upstream additionally starts
the normal notification script through `nohup`; notifier and click failures are
reported by the plugin without becoming Herdr server failures. Dotfiles apply
also treats installation, enablement, and reload failures as warnings so a
notification outage cannot block environment deployment.

## Considered options

- Keep the Python implementation in this repository.
- Extract that implementation into a new repository.
- Adopt another notification plugin with a platform or targeting mismatch.
- Adopt the maintained upstream plugin at a tested release.

## Decision

Adopt `yankewei/herdr-focus-notify` release `v0.5.1`, pinned to its reviewed
commit `560e70c5e1716fa0781b6746821ce8676f70a811`. Install it with `herdr plugin
install yankewei/herdr-focus-notify --ref
560e70c5e1716fa0781b6746821ce8676f70a811 -y`, enable the upstream ID
`herdr-focus-notify`, and uninstall the superseded local ID
`seigi.focus-notify`. Remove the local manifest, Python implementation, linking
script, and implementation tests.

Dotfiles continues to own personal policy and machine dependencies:

- Homebrew installs Cargo. Chezmoi installs the official `alerter` 26.5 release
  archive at an explicit SHA-256 and exposes it through `~/.local/bin`; this
  avoids trusting the health of unrelated formulae in its Homebrew tap.
  Package-private Rust dependencies stay declared and locked by the upstream
  package. Terminal applications remain selected and configured here.
- `config.toml` keeps native Herdr toast delivery off, preventing duplicate
  notification producers.
- The plugin learns the frontmost terminal per workspace at runtime; no package
  code or install step overwrites chezmoi-managed terminal or Herdr config.
- The tested commit is immutable and is not delegated to the auto-update trust
  list. Updating is an explicit reviewed pin change, followed by upstream
  release review and the deployment checks in this repository.

These are also the packaging conventions for a future Command Palette
migration: install source-owned plugins through Herdr at an explicit commit,
keep host dependencies and user policy in dotfiles, retain package-private
dependencies and implementation tests upstream, and test only
installation/deployment behavior here. No in-house plugin framework is required.

## Consequences

Installation works without this checkout because Herdr fetches the pinned
GitHub commit. A successful apply removes the old managed directory through
`.chezmoiremove`, attempts to uninstall the known local ID, and installs the
upstream plugin. Inspection, uninstall, installation, enablement, and reload
failures are warnings so notification setup cannot block the rest of apply.
This migration does not inspect unrelated plugins or claim that Focus Notify is
the machine's only notification producer.

Removal is `herdr plugin uninstall herdr-focus-notify`, followed by deleting its
entry and dependencies when no other consumer remains. Rollback normally means
changing `--ref` to a previously reviewed upstream commit and reapplying. Restoring
the local implementation requires reverting this decision's migration commit;
the local plugin ID is not preserved as an alias because duplicate event hooks
would recreate duplicate notifications.

The supported live configuration is a local macOS Herdr 0.9.0 client in a
dotfiles-managed terminal, after a normal pane focus has established that
workspace's terminal binding. Upstream tests cover the agent-focus plus returned
tab-focus sequence, including shared-server clients. Real notification display,
learned Ghostty or Kitty binding, and click targeting still need a live macOS GUI
session. CI proves the managed dependencies and pinned Herdr CLI calls; after
deployment, focus one pane from each terminal in use, invoke `herdr plugin action
invoke --plugin herdr-focus-notify test`, click the notification, and record
that the intended pane and tab are shown. This evidence is intentionally
reported separately from CI.
