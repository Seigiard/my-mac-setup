---
title: "user-prompt-skill-eval hook is deployed but never wired"
short_description: "home/private_dot_claude/hooks/executable_user-prompt-skill-eval.sh ships via chezmoi but private_settings.json.tmpl has no UserPromptSubmit block (the blocks planned in docs/plans/2026-08-10-001 never landed), so the skill-evaluation preamble it would inject never runs and the file reads as live."
type: "follow-up"
category: "agent-platform"
tags: ["hooks","claude-code"]
date: "2026-09-03"
status: "open"
priority: "low"
---

## Why this exists

`home/private_dot_claude/hooks/executable_user-prompt-skill-eval.sh` is deployed by chezmoi and would inject a mandatory skill-evaluation and tool-routing preamble on every user prompt, but `home/private_dot_claude/private_settings.json.tmpl` contains no `UserPromptSubmit` block (verified by grep), so the hook never fires. The `UserPromptSubmit` and `PreCompact` wiring planned in `docs/plans/2026-08-10-001-feat-herdr-task-sync-plan.md` never landed. A deployed-but-dead hook misleads maintenance: it reads as live policy and could be silently activated (or duplicated) by a future settings change.

## Scope

Wire it or delete it:

- Wire: add a `UserPromptSubmit` block to `private_settings.json.tmpl` invoking the hook, and confirm the preamble's cost per prompt is still wanted.
- Delete: remove the hook file from `home/private_dot_claude/hooks/`.

Either way the repo stops carrying a hook whose deployment state and wiring state disagree.

## Open decisions

- Whether the mandatory skill-evaluation preamble is still desired at all; it predates the current skill-routing section in the global CLAUDE.md, which may have superseded it.
