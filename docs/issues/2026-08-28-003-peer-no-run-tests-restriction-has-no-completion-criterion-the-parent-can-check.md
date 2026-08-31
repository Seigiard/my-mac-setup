---
title: "Peer no-run-tests restriction has no completion criterion the parent can check"
short_description: "Nothing detects a peer or persona subagent that ran the test suite anyway"
type: "follow-up"
category: "agent-platform"
tags: ["se-code-review","verification"]
date: "2026-08-28"
status: "open"
priority: "medium"
---

## Why this exists

The se-code-review shared review contract instructs each peer to use static inspection only and to append that same restriction to every persona/reviewer subagent prompt. Compliance is therefore twice removed: parent -> peer -> persona subagent. The demand is stated but no check exists — neither the report validation in 'Dispatch fresh peers' nor 'Synthesize reports' can tell a compliant envelope from one produced by a peer that ran the suite. The restriction exists so the parent owns test execution after synthesis and accepted fixes; a silent violation costs wall-clock time on duplicate suite runs and can leave a mutated tree the parent then reviews as clean.

## Scope

Either require each peer to declare its tool usage in the report envelope so the parent can reject a violating one, or accept the restriction as best-effort and say so explicitly in the skill so no reader assumes it is enforced. Applies to se-code-review; check whether se-doc-review and se-simplify carry the same unenforced demand.

## Open decisions

Whether a self-declared tool-usage field is trustworthy enough to gate on, given the same agent is the one under restriction.
