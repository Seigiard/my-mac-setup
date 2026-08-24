---
title: "Code review secret gate rejects API-key fixture"
short_description: "The se-code-review external harness refuses the current tree because gitleaks reports the intentional issue-writer API-key redaction fixture as a new generic-api-key finding outside its baseline."
type: "bug"
category: "se-pipeline"
tags: ["code-review","secret-scan","smithers"]
date: "2026-08-24"
status: "open"
priority: "medium"
---

## Why this exists

The `/se-code-review` external harness refused the snapshot before launching
either Claude or OpenCode. Its whole-tree gitleaks gate reported
`home/private_dot_claude/dot_smithers/workflows/lib/issue-writer.test.ts` as a
new `generic-api-key` finding not present in the stored baseline. The matching
string is an intentional redaction fixture, but bypassing the gate would send a
snapshot that the safety policy explicitly rejected.

This prevents the required independent review legs for unrelated branches
until the fixture and baseline agree.

## Scope

- Confirm the reported string is only a synthetic redaction fixture.
- Redact or allowlist the fixture without weakening production secret scans.
- Refresh the managed baseline through its documented workflow if the finding
  is intentionally accepted.
- Re-run `/se-code-review` and confirm both external legs receive the snapshot.

## Open decisions

None.
