---
title: Extract Herdr worktree setup
status: accepted
date: 2026-09-18
supersedes: []
---

# ADR-0018: Extract Herdr Worktree Setup

## Context

The worktree setup event handler, manifest, behavior tests, and lifecycle
documentation lived in this dotfiles repository even though Herdr loads the
handler as a reusable plugin. Keeping that implementation here coupled plugin
installation to a temporary chezmoi checkout and mixed reusable behavior with
repository-specific preparation policy.

The generated-worktree marker is a cross-package contract: worktree setup
writes it, while `herdr-worktree-identity` consumes it as authorization for a
task-derived branch rename. Worktree creation itself remains native Herdr
behavior and is not assumed to pass through the provenance PATH wrapper.

## Considered options

- Keep the implementation and local link script in dotfiles.
- Create a shared runtime framework for Herdr plugins.
- Extract Worktree Setup into its own package and leave policy/configuration in
  dotfiles.

## Decision

Own the reusable implementation, manifest, behavioral tests, documentation, CI,
and releases in
[`Seigiard/herdr-worktree-setup`](https://github.com/Seigiard/herdr-worktree-setup).
The package is installed and enabled at reviewed immutable commit
`70048c616979719aa592df36f37ec076227b2ac8` (release `v0.1.1`).

Keep the repository-keyed `copy`, `steps`, and `fresh-base` policy in
`config.toml` managed by this repository. A one-time chezmoi migration replaces
the old local plugin with the pinned package and retains the old files when
installation or enablement fails. The normal GitHub plugin installer owns later
reviewed updates; uninstalling the package does not remove the policy file.

The package writes `herdr-generated-worktree` atomically in the Git per-worktree
administrative directory, with the generated branch on line one. It observes
`worktree.created` and does not create resources or maintain a provenance
registry. Unsupported creation paths remain unknown-provenance paths.
