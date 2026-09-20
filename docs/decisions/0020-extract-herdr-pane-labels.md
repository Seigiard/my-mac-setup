---
title: Extract Herdr Pane Labels
status: accepted
date: 2026-09-18
supersedes: []
---

# ADR-0020: Extract Herdr Pane Labels

## Context

Pane Labels had grown into the reusable Herdr runtime: complete-snapshot
reconciliation, agent aliases, pane and tab labels, workspace origin, Git
location/status metadata, and a sweep daemon. Dotfiles also carried its
private libraries, manifest, lifecycle scripts, and behavior suite. That made
the runtime depend on a temporary chezmoi checkout and left alias policy
shared by multiple callers without a package boundary.

The package must preserve the existing writer safety rules while allowing
running Herdr sessions to move from the local layout without two active label
writers or stale work being applied to a new pane.

## Considered options

- Keep the implementation in dotfiles and continue linking it locally.
- Extract only the manifest and keep the executable and alias library here.
- Extract the runtime and alias policy into a standalone package, leaving
  presentation configuration and one-time migration in dotfiles.

## Decision

Own the reusable implementation, private runtime libraries, manifest,
diagnostics, lifecycle actions, behavior tests, documentation, CI, and
releases in
[`Seigiard/herdr-pane-labels`](https://github.com/Seigiard/herdr-pane-labels).
The reviewed deployment pin is commit `aba61eb788c5fe0630dc570d96fd14683e2f63c7` (`v0.2.3`). The plugin ID remains
`seigi.pane-labels`; the `sweep` action and event scopes remain compatible.

The package owns alias policy and exposes one supported consumer boundary:
`herdr-pane-labels --alias-candidates <seed>`. It returns deterministic
candidates only. It does not promise atomic reservation; child and peer
launchers still treat Herdr's `agent_name_taken` response as the concurrency
boundary. The package's reconciler uses the same private alias implementation.

Dotfiles consumes the package, owns the sidebar rows and personal Herdr
presentation settings, and keeps only a one-time migration. That migration
disables the local plugin, drains and verifies the old daemon, freezes child
launches, installs and enables the package, performs strict reconciliation for
each running session, verifies the package CLI boundary, and removes the old
layout only after success. A failure restores the old executable, aliases,
child launcher, plugin registration, and daemon path.

The package preserves complete-snapshot reconciliation, generation checks,
target identity revalidation, explicit metadata clearing, stale Git-location
handling, and one active label writer per socket. Progress reporting remains a
separate publisher and is not part of this package.

## Consequences

A clean home can install and update Pane Labels without this dotfiles checkout.
The package's build step installs the runtime CLI and private libraries under
the user's local directories so `herdr-child` and `herdr-peer-alias` do not
source a second alias pool. Removing the package requires removing its CLI
shim as part of package lifecycle cleanup; dotfiles no longer owns a permanent
copy of the implementation.

Implementation tests and package lifecycle tests live upstream. This
repository retains deployment, pin, consumer-interface, and migration tests.
