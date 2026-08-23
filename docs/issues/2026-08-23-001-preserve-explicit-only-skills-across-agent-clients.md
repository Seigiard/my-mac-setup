---
title: "Preserve explicit-only skills across agent clients"
short_description: "`eli5` and `open-questions` need one canonical source plus client-specific invocation adapters because OpenCode ignores the `disable-model-invocation` frontmatter from Claude Code."
type: "follow-up"
category: "agent-platform"
tags: ["skills","opencode","claude-code","pi"]
date: "2026-08-23"
status: "open"
priority: "medium"
---

## Why this exists

`eli5` and `open-questions` are intentionally user-invoked workflows: each interrupts the current task and must run only after an explicit request. Claude Code and Pi honor `disable-model-invocation: true`, but OpenCode ignores this frontmatter and exposes a linked skill for automatic model selection. Copying their content into OpenCode commands would preserve invocation behavior but create independent versions that can drift.

## Scope

Define one canonical source for each workflow and generate or link the client-facing packaging from that source. Preserve explicit-only invocation in Claude Code and Pi, and expose equivalent manually invoked OpenCode commands without making either workflow model-discoverable. Keep descriptions, workflow bodies, and future edits synchronized by construction. Add tests that verify deployed targets, invocation metadata, and generated content remain consistent across clients. Document ownership and the update procedure in the agent setup inventory.

## Open decisions

Choose the canonical representation and location for shared workflow content. Decide whether chezmoi templates, generated files, or thin client adapters should package that content. Confirm the exact Pi invocation semantics and the supported OpenCode command format before implementation. Decide whether a validation test should compare rendered content or enforce links to a shared body.
