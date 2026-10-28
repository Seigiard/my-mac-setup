---
title: Replace Agent Intercom with herdr-peer
status: accepted
date: 2026-10-12
supersedes:
  - 0018-use-a-shared-intercom-for-location-independent-agent-communication
  - 0021-recover-intercom-launch-claims-without-a-successor
  - 0022-centralize-intercom-admission-in-the-recovery-engine
---

# ADR-0024: Replace Agent Intercom with herdr-peer

## Context

Agent Intercom required a broker, client adapters, a launcher, a recovery
engine, and a launchd observer. The stack could fail when a client was restarted
in a used pane and kept OpenCode on a V1 plugin API. Herdr already delivers a
prompt to a live agent alias, and `herdr-child` uses that path for managed child
communication.

## Considered options

- Keep Agent Intercom and repair its adapters and recovery paths. This retains a
  second communication system and its lifecycle machinery.
- Use Claude Code cross-session messaging. It does not cover all supported
  clients and adds a separate peer channel.
- Use a small wrapper around `herdr agent prompt` for existing Herdr panes.

## Decision

Use `herdr-peer` for peer messaging between already-running Herdr agent panes.
It lists peers and sends `send`, `ask`, or `reply` prompts with a versioned
marker. It keeps no state and does not wait for replies. `herdr-child` remains
the owner of child launch, supervision, decisions, and cleanup.

Remove Agent Intercom, its adapters, installer, launchd recovery service, and
tests. Disable Claude Code cross-session messaging so the managed environment
has one peer-message channel.
