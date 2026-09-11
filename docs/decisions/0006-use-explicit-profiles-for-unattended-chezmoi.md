---
title: Use explicit profiles for unattended chezmoi
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0006: Use explicit profiles for unattended chezmoi

## Context

Unattended chezmoi runs must not wait for interactive 1Password authorization or
mistake unavailable credentials for intentional deletion. At the same time, a
host diff cannot honestly claim to verify secret-sensitive targets without their
credentials. The failure and selected profile model are documented in
`docs/plans/2026-09-04-1126-fix-unattended-chezmoi-plan.md`.

## Considered options

- Manipulate `PATH`, add timeouts, or use a 1Password service account.
- Skip secret-sensitive targets in every unattended environment.
- Require each unattended caller to select a full-fixture or host-partial
  profile through one repository launcher.

## Decision

Every repository-owned unattended chezmoi call goes through the shared launcher
and names a profile. `full-fixture` requires disposable-home authority and all
canary credentials, then renders every registered target. `host-partial` omits
the named secret-sensitive targets and reports that omission. Interactive use
continues to read real credentials from 1Password.

## Consequences

Disposable environments get complete reproducible evidence without real
secrets. Host comparison remains safe but explicitly partial. The central target
inventory and the profile-specific template branches must change together. The
omission contract depends on verified chezmoi 2.72.1-or-newer behavior: older
versions fail closed, and upgrades must pass the omission and render
compatibility checks.
