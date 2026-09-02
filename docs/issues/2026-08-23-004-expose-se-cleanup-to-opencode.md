---
title: "Expose local se workflows to OpenCode"
short_description: "OpenCode now receives all eight local se-* workflows through managed symlinks while Claude auto-discovery remains disabled to preserve explicit-only invocation boundaries."
type: "follow-up"
category: "agent-platform"
tags: ["skill","opencode","se-workflows","cross-client"]
date: "2026-08-23"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-22-0733-feat-se-cleanup-plan.md"
closed: "2026-08-31"
---

## Why this exists

The se-cleanup implementation created only home/private_dot_claude/skills/se-cleanup/SKILL.md. The managed shell sets OPENCODE_DISABLE_EXTERNAL_SKILLS=1 and OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1, so OpenCode cannot discover that Claude skill automatically. The curated OpenCode skill directory contains no se-cleanup adapter, although no documented product decision makes this post-merge workflow Claude-only.

## Scope

Add a managed OpenCode symlink adapter for se-cleanup that points to the canonical Claude skill, extend the curated-skill smoke case to cover it, and update docs/agent-setup-inventory.md. Verify that OpenCode receives the skill after a disposable chezmoi apply without duplicating the skill body or weakening the existing discovery-disable boundary.

## Open decisions

Confirm whether se-cleanup should be the only additional curated operational skill or whether the same cross-client gap affects other locally authored se-* workflows; keep any broader inventory correction in separately scoped follow-up work.

## Resolution

Added canonical OpenCode symlink adapters for all eight local se-* workflows, made shared wrapper instructions client-neutral, updated the inventory, and extended template and deployed smoke coverage. Calibrated templates_test.sh red before the adapters and green afterward (146 assertions). A focused test-ubuntu service run applied the checkout and passed both the curated-skill and explicit-only smoke contracts; the full make test-ubuntu run reached post-apply coverage but was incomplete because unrelated scripts test 258 asserted an untruncated nested test name in a narrow TTY.
