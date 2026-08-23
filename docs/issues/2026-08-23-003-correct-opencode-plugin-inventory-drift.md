---
title: "Correct OpenCode plugin inventory drift"
short_description: "The inventory says OpenCode installs no plugin through plugin[], but the managed opencode.json installs Compound Engineering there."
type: "follow-up"
category: "agent-platform"
tags: ["inventory","opencode"]
date: "2026-08-23"
status: "open"
priority: "low"
---

## Why this exists

`docs/agent-setup-inventory.md` says that OpenCode installs no plugins through
`plugin[]`, while `home/private_dot_config/opencode/opencode.json.tmpl` installs
the Compound Engineering plugin there. The contradiction makes the manual
reinstall inventory unreliable.

## Scope

Update the OpenCode plugin inventory to match the managed `plugin[]` value and
state that chezmoi owns the configuration. Keep the inventory's bundle-level
listing rule instead of enumerating the plugin's internal skills and agents.

## Open decisions

None.
