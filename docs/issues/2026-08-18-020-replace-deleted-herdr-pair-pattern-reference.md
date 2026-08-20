---
title: Replace the deleted herdr-pair pattern reference
type: follow-up
date: 2026-08-18
status: done
closed: 2026-08-18
---

## Why this exists

`docs/plans/2026-08-18-1254-fix-command-palette-defects-plan.md` points to `home/private_dot_claude/skills/herdr-pair/scripts/spawn-partner.sh:37` as the repository's hard-dependency error pattern. The child agent launch contract deletes the complete `herdr-pair` skill, so that implementation plan now points to a path available only in Git history.

`docs/plans/2026-08-13-001-feat-dynamic-flow-composition-plan.md` also names the removed read-only `ask-agent` invocation path. The replacement `ask-in-herdr` skill is live-agent-only and keeps an unscoped callback shell, so the old statement is no longer a valid implementation instruction.

The child launch work does not edit planning documents during execution. This issue keeps both stale references visible without mutating either planning artifact as execution progress.

## Scope

Before executing the command-palette defects plan, replace its deleted pattern reference with a surviving script that checks a required binary, writes a concrete error to stderr, and exits non-zero. Preserve the command-palette plan's required message content for `fzf`.

Before executing the dynamic-flow composition plan, replace its `ask-agent` requirement with the current Smithers external-agent contract. Do not route a headless Smithers leg through the herdr-only consult.

## Decisions

- Do not cite another script. Specify the short `fzf` check and its required failure behavior directly in the plan.
- Do not name a historical commit or path. Git history is unnecessary for implementing this check.

## Resolution

The command-palette plan now specifies the `fzf` preflight directly: call `shutil.which("fzf")`, show the required message through the existing interactive or non-interactive path when it returns `None`, and exit non-zero. It no longer cites a surviving or historical script because the required behavior is clearer and more durable than an implementation reference.

The dynamic-flow composition plan now uses the implemented Smithers contract for external legs: `external: true` with `externalContract: { dispatchScan: true, invocation: "read-only-external-agent" }`. It explicitly forbids routing those headless legs through the herdr-only `ask-in-herdr` skill.
