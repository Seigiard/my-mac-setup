---
title: Split skill ownership by source provenance
status: accepted
date: 2026-09-11
supersedes: []
---

# ADR-0010: Split skill ownership by source provenance

## Context

The global skill namespace contains both externally maintained skills and skills
whose source belongs to this dotfiles repository. The managed Skills CLI wrapper
accepts only an `owner/repo` source, installs external content, and records that
ownership in its global lock. It cannot install the repository-owned local source
tree through its current contract.

## Considered options

- Make chezmoi copy and update every external skill.
- Extend or replace the Skills CLI contract so it can own local source too.
- Divide ownership by provenance while reserving repository-owned names in the
  shared namespace.

## Decision

The Skills CLI owns selected upstream skills and their update lifecycle. Chezmoi
owns skills authored in this repository and deploys their canonical source into
the global namespace. `home/private_dot_config/agent-skills/repository-owned`
reserves those names so wildcard upstream installs cannot claim them.

## Consequences

Each skill has one source owner without forcing external packages into this
repository or local source into an unsupported installer. The selected-skill
manifest, repository-owned reservation list, and chezmoi-owned skill tree must
remain synchronized to prevent collisions.
