---
title: "Make writing-for-agents multi-agent aware"
short_description: "The shared writing guidance must distinguish Claude Code, OpenCode, and Pi packaging, discovery, invocation, and repository-specific ownership rules."
type: "follow-up"
category: "agent-platform"
tags: ["skills","opencode","claude-code","pi","documentation"]
date: "2026-08-23"
status: "done"
priority: "medium"
closed: "2026-08-25"
---

## Why this exists

`writing-for-agents/SKILL.md` presents universal guidance, but `SKILL-MECHANICS.md` encodes Claude Code assumptions. It treats `disable-model-invocation: true` as portable, places skills and shared references under `~/.claude`, and does not explain how OpenCode or Pi discover and invoke skills. An agent following this guidance can create files in the wrong source tree, apply unsupported frontmatter, or introduce duplicate sources that drift under chezmoi.

## Scope

Rewrite the mechanics guidance around a universal core plus explicit client-specific sections for Claude Code, OpenCode, and Pi. Document each client discovery root, project and global scope, supported invocation controls, unknown-frontmatter behavior, symlink behavior, and shared-reference constraints. Add the repository management layer: edit managed sources under `home/`, check `.chezmoiexternal.toml` before adding content, preserve one canonical source, use thin adapters when client packaging differs, and update `docs/agent-setup-inventory.md`. Keep the general writing guidance client-neutral. Add focused checks that prevent the documented paths and invocation semantics from drifting from managed configuration.

## Open decisions

Decide whether client mechanics remain in one matrix or split into progressively disclosed references. Define which claims can be checked automatically against repository configuration and which require documented upstream verification. Decide whether the skill should direct agents to inspect current client documentation before adding a new cross-client skill.

## Resolution

Reworked skill mechanics into explicit Claude Code, OpenCode, and Pi sections; documented managed-source ownership and adapter rules; exposed the canonical writing-for-agents skill to OpenCode through a managed symlink; updated inventory and focused deployment checks.
