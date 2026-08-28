---
title: "Peer test rules duplicated between se-code-review SKILL.md and the Smithers workflow"
short_description: "The no-tests restriction and tautological-tests criterion exist as two independently editable copies"
type: "chore"
category: "se-pipeline"
tags: ["se-code-review","duplication"]
date: "2026-08-28"
status: "open"
priority: "medium"
---

## Why this exists

The no-run-tests restriction and the 'Tautological tests considered harmful' criterion are inlined in two separate runtimes: home/private_dot_claude/skills/se-code-review/SKILL.md (shared review contract block) and home/private_dot_claude/dot_smithers/workflows/se-code-review.tsx (consultHardRules extraRules). Changing the rule requires two synchronized edits, and the copies have already drifted — the .tsx version drops the quotation marks that scope the criterion handed to the testing persona. Inlining is correct in both places because each dispatches a fresh-context agent that cannot reach a pointer, so the fix is a shared origin rather than a pointer.

## Scope

Give the two rule strings one origin the workflow imports and the skill quotes verbatim, or add a check that fails when the two copies diverge. Out of scope: changing what the rules say.

## Open decisions

Whether a Markdown skill can practically import from a TypeScript module, or whether a drift test is the cheaper mechanism.
