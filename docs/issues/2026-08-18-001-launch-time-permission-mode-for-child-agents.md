---
title: "Set a child agent's permission mode at launch instead of inheriting bypassPermissions"
short_description: "Set a child agent's permission mode at launch instead of inheriting bypassPermissions"
type: "idea"
category: "agent-platform"
tags: ["agent-platform","idea"]
date: "2026-08-18"
status: "open"
priority: "high"
parent-plan: "docs/plans/2026-08-17-1630-feat-child-agent-launch-contract-plan.md"
---

## Why this exists

The child agent launch contract lets the caller pick a child's tool posture: read-only for review and consult work, read-write for work that changes files. Read-only there means one thing only — the child holds no file-writing tools. It is not a write boundary, and the plan says so.

The reason is measured. A claude child started with `--disallowed-tools` came up in `bypass permissions` mode, inherited from the shared Claude Code settings at `home/private_dot_claude/private_settings.json.tmpl:132`. Tool flags decide which tools exist; they do not narrow the permission posture. A read-only child that still holds a shell can write a file through it. Three reviewers in the plan's local review, four in an external review on opencode, and a residual note from an external review on claude all landed on this independently.

The plan accepts the gap rather than closing it, because sandboxing the child is the next piece of work and would supersede launch-time enforcement one iteration later. This issue records the option that was not taken, so the choice stays visible if the sandbox slips.

## Scope

Investigate whether the launch command can set each child kind's permission mode explicitly instead of letting it inherit the parent's.

Per kind, the shape to test:

- **claude** — `--permission-mode manual` (or whichever mode the installed CLI exposes for it) plus a permission scoped to the return-channel command alone, so a read-only child can still run `herdr agent prompt` and nothing else. The plan's requirement R9 makes that command mandatory in every posture, so it must survive the narrowing.
- **opencode** — write denials carried in the `OPENCODE_PERMISSION` environment variable, alongside the `question` denial the plan already puts there. opencode's permission actions are per-tool-id, so `edit` and `bash` are addressable; whether a narrower `bash` grant exists is the open part.
- **pi** — no narrow surface is known. `--tools` gates whole tools, so granting the return-channel command means granting `bash` entirely. The plan therefore refuses the read-only posture for a `pi` child. Check whether a later pi release changes that.

What makes this worth doing even after a sandbox exists: a sandbox contains what the child can reach on the filesystem; a permission mode contains what it may do inside its own worktree. They are different boundaries and the second one is cheaper to reason about per task.

Out of scope: the sandbox itself, and any change to the parent's own permission mode.

## Open decisions

- Whether this lands before the sandbox, after it, or not at all once the sandbox is measured in practice.
- Whether a scoped permission actually binds when the child would otherwise inherit `bypassPermissions`, or whether the inherited mode wins regardless of what the launch command passes. This is the single fact that decides whether the whole idea works.
- Whether refusing a read-only `pi` child stays the answer, or `pi` leaves the supported child-kind list entirely.
