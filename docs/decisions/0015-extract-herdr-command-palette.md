---
title: Extract the Herdr Command Palette
status: accepted
date: 2026-09-16
supersedes: []
---

# ADR-0015: Extract the Herdr Command Palette

## Context

This repository carried the Command Palette manifest, Python implementation,
helpers, and 61 behavior tests beside personal commands and keybindings. That
made dotfiles the implementation owner and required a local `herdr plugin link`
whose absolute path could outlive a temporary checkout.

The source-backed comparison in
[`2026-09-16-herdr-command-palette-alternatives-research.md`](../plans/2026-09-16-herdr-command-palette-alternatives-research.md)
evaluated HerdrPlus and the realistic command-palette candidates from
`awesome-herdr` and the official plugin marketplace. HerdrPlus came closest,
but would require replacing shortcut-first search, the aggregate command file,
typed pane/tab/plugin dispatch, shell-value validation, and smart close. Other
candidates preserved fewer of those contracts. Adopting any candidate would be
a product rewrite rather than a behavior-preserving packaging change.

The repository also contained three `.herdr/command-palette` files solely to
scope dotfiles checks to this project. The maintainer prefers one user-owned
configuration file and does not want command-palette files added to each
repository.

## Considered options

- Adopt HerdrPlus and accept its file-per-action model and behavioral gaps.
- Adopt another marketplace palette and retain local compatibility helpers.
- Keep linking the implementation from dotfiles.
- Extract the implementation and add repository scoping to the existing single
  user-owned command file.

## Decision

Own the reusable implementation in
[`Seigiard/herdr-command-palette`](https://github.com/Seigiard/herdr-command-palette).
Keep the existing plugin ID, action IDs, and pane IDs so keybindings and command
callers do not need compatibility shims. The package owns the manifest, Python
implementation, helper scripts, documentation, CI, releases, and behavior
tests. It supports Herdr 0.7.0 or newer on macOS and Linux and declares Python
3.9 and fzf 0.56 as runtime dependencies.

Dotfiles installs an immutable reviewed commit with `herdr plugin install
Seigiard/herdr-command-palette --ref <commit> -y`, enables
`seigi.command-palette`, and removes the former local plugin directory. The
cutover uninstalls `seigi.command-palette` only when Herdr reports
`source.kind = local`; a subsequent apply updates the GitHub-managed package in
place. Updating means reviewing a newer package release and changing the pin.
Removal is `herdr plugin uninstall seigi.command-palette`; the separately
managed command file is intentionally preserved.

Personal commands, shortcuts, keybindings, terminal hints, and fzf installation
remain here. Repository-specific commands use
`repositories = ["owner/repository"]` in the same managed `commands.toml`.
The package normalizes the active Git remote, exposes its root through
`{project_root}`, and includes matching entries without writing anything into
the repository. Read-only `.herdr/command-palette` discovery remains package
compatibility behavior, but this repository no longer uses it.

Existing palette issues move to the package repository so their history and
links remain intact. Dotfiles retains only deployment and personal-policy work.

## Consequences

The package installs into a clean home without this checkout and leaves its
Herdr config directory empty instead of seeding or competing with chezmoi.
Implementation tests move with the package. This repository verifies the pinned
installer, local-to-GitHub cutover, stable keybindings, one-file policy, runtime
dependencies, and disposable-home deployment.

The package is now an owned maintenance surface because no existing plugin met
the accepted behavior. That cost is explicit and isolated from personal
configuration. Future feature work, sizing decisions, dispatch verification,
and implementation test fixes belong in the package repository.
