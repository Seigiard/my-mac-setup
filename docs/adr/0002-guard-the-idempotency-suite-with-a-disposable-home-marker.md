---
title: Guard the idempotency suite with a disposable-home marker
status: accepted
date: 2026-08-21
supersedes: []
---

# ADR-0002: Guard the idempotency suite with a disposable-home marker

## Context

`tests/idempotent.bats` runs real chezmoi commands without `--destination`, so
chezmoi writes to `$HOME`. The managed run scripts also address `$HOME`
directly. A developer who runs the file can therefore overwrite live dotfiles,
install packages, and change macOS settings.

## Considered options

- Require an explicit repository-owned marker that declares `$HOME`
  disposable. This fails closed and keeps the existing CI and Docker coverage.
- Add `--destination` and a fresh `--config`. This does not contain run scripts
  that address `$HOME` directly. A fresh config also resets persistent run
  state and can re-fire package installation and macOS changes on the host.
- Rely only on the Makefile exclusion. This protects one entry point but leaves
  direct `bats tests/idempotent.bats` runs unsafe.

## Decision

Require `MMS_DISPOSABLE_HOME=1` before any idempotency test runs a chezmoi
command. GitHub Actions and every Docker test service set the marker. Platform
facts only detect a disposable runner that lost the marker; they never grant
permission to run.

The Makefile exclusion remains as independent defense. A self-hosted GitHub
runner with a persistent `$HOME` remains a known risk because the workflow
marker cannot distinguish it from a disposable hosted runner. This repository
currently uses only GitHub-hosted runners and accepts that residual risk.
